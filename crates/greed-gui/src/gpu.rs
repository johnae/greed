//! Drawing scenes with wgpu: one pipeline draws every quad, colored
//! rectangles and glyphs from the atlas texture alike, as instances of a
//! four-vertex strip. Images are quads too, each drawn with its own
//! texture in place of the atlas.

use std::collections::HashMap;

use greed_core::image::ImageId;
use greed_core::render::ImagePlacement;
use wgpu::util::DeviceExt;

use crate::draw::{Instance, Scene};
use crate::text::Atlas;

const SHADER: &str = r"
struct Screen { size: vec2<f32>, pad: vec2<f32> };
@group(0) @binding(0) var<uniform> screen: Screen;
@group(0) @binding(1) var atlas: texture_2d<f32>;
@group(0) @binding(2) var pick: sampler;

struct Quad {
    @location(0) pos: vec2<f32>,
    @location(1) size: vec2<f32>,
    @location(2) uv: vec4<f32>,
    @location(3) color: vec4<f32>,
    @location(4) kind: u32,
};

struct Out {
    @builtin(position) pos: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) color: vec4<f32>,
    @location(2) @interpolate(flat) kind: u32,
};

@vertex
fn vs(@builtin(vertex_index) v: u32, q: Quad) -> Out {
    let corner = vec2<f32>(f32(v & 1u), f32(v >> 1u));
    let p = q.pos + corner * q.size;
    var o: Out;
    o.pos = vec4<f32>(p.x / screen.size.x * 2.0 - 1.0, 1.0 - p.y / screen.size.y * 2.0, 0.0, 1.0);
    o.uv = mix(q.uv.xy, q.uv.zw, corner);
    o.color = q.color;
    o.kind = q.kind;
    return o;
}

@fragment
fn fs(o: Out) -> @location(0) vec4<f32> {
    let t = textureSampleLevel(atlas, pick, o.uv, 0.0);
    if o.kind == 0u {
        return o.color;
    }
    if o.kind == 1u {
        return vec4<f32>(o.color.rgb, o.color.a * t.a);
    }
    return t;
}
";

/// The GPU state for drawing: the pipeline, the atlas texture, the images'
/// textures and a buffer for each frame's quads.
pub struct Gpu {
    pub device: wgpu::Device,
    pub queue: wgpu::Queue,
    pipeline: wgpu::RenderPipeline,
    layout: wgpu::BindGroupLayout,
    bind_group: wgpu::BindGroup,
    screen: wgpu::Buffer,
    atlas: wgpu::Texture,
    /// Images are scaled to fit their cells, so they're sampled smoothly.
    smooth: wgpu::Sampler,
    images: HashMap<ImageId, wgpu::BindGroup>,
    quads: wgpu::Buffer,
    capacity: usize,
}

impl Gpu {
    /// A device without a window, for drawing to textures.
    pub fn headless(format: wgpu::TextureFormat, atlas_size: u32) -> Option<Self> {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle());
        let adapter =
            pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions::default()))
                .ok()?;
        let (device, queue) =
            pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor::default())).ok()?;
        Some(Self::new(device, queue, format, atlas_size))
    }

    pub fn new(
        device: wgpu::Device,
        queue: wgpu::Queue,
        format: wgpu::TextureFormat,
        atlas_size: u32,
    ) -> Self {
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("greed"),
            source: wgpu::ShaderSource::Wgsl(SHADER.into()),
        });
        let screen = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("screen"),
            size: 16,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let atlas = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("atlas"),
            size: wgpu::Extent3d {
                width: atlas_size,
                height: atlas_size,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("nearest"),
            ..Default::default()
        });
        let smooth = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("smooth"),
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });
        let layout = bind_group_layout(&device);
        let bind_group = bind(&device, &layout, &screen, &atlas, &sampler);
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("greed"),
            bind_group_layouts: &[Some(&layout)],
            immediate_size: 0,
        });
        let attributes = wgpu::vertex_attr_array![
            0 => Float32x2, 1 => Float32x2, 2 => Float32x4, 3 => Float32x4, 4 => Uint32
        ];
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("greed"),
            layout: Some(&pipeline_layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs"),
                compilation_options: wgpu::PipelineCompilationOptions::default(),
                buffers: &[Some(wgpu::VertexBufferLayout {
                    array_stride: std::mem::size_of::<Instance>() as u64,
                    step_mode: wgpu::VertexStepMode::Instance,
                    attributes: &attributes,
                })],
            },
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleStrip,
                ..Default::default()
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fs"),
                compilation_options: wgpu::PipelineCompilationOptions::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: Some(wgpu::BlendState::ALPHA_BLENDING),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            multiview_mask: None,
            cache: None,
        });
        let capacity = 1024;
        let quads = Self::quad_buffer(&device, capacity);
        Self {
            device,
            queue,
            pipeline,
            layout,
            bind_group,
            screen,
            atlas,
            smooth,
            images: HashMap::new(),
            quads,
            capacity,
        }
    }

    /// Makes textures for the images `placements` show, from their PNGs in
    /// `pngs`, and drops those of images no longer shown. One too big for
    /// the GPU is scaled down to fit.
    pub fn place_images(
        &mut self,
        placements: &[ImagePlacement],
        pngs: &HashMap<ImageId, Vec<u8>>,
    ) {
        self.images
            .retain(|id, _| placements.iter().any(|p| p.id == *id));
        let limit = self.device.limits().max_texture_dimension_2d;
        for p in placements {
            if self.images.contains_key(&p.id) {
                continue;
            }
            let Some(decoded) = pngs.get(&p.id).and_then(|png| {
                image::load_from_memory_with_format(png, image::ImageFormat::Png).ok()
            }) else {
                continue;
            };
            let decoded = if decoded.width().max(decoded.height()) > limit {
                decoded.resize(limit, limit, image::imageops::FilterType::Triangle)
            } else {
                decoded
            };
            let rgba = decoded.into_rgba8();
            let texture = self.device.create_texture_with_data(
                &self.queue,
                &wgpu::TextureDescriptor {
                    label: Some("image"),
                    size: wgpu::Extent3d {
                        width: rgba.width(),
                        height: rgba.height(),
                        depth_or_array_layers: 1,
                    },
                    mip_level_count: 1,
                    sample_count: 1,
                    dimension: wgpu::TextureDimension::D2,
                    format: wgpu::TextureFormat::Rgba8Unorm,
                    usage: wgpu::TextureUsages::TEXTURE_BINDING,
                    view_formats: &[],
                },
                wgpu::util::TextureDataOrder::LayerMajor,
                &rgba,
            );
            let group = bind(
                &self.device,
                &self.layout,
                &self.screen,
                &texture,
                &self.smooth,
            );
            self.images.insert(p.id, group);
        }
    }

    fn quad_buffer(device: &wgpu::Device, capacity: usize) -> wgpu::Buffer {
        device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("quads"),
            size: (capacity * std::mem::size_of::<Instance>()) as u64,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        })
    }

    /// Copies glyphs new to `atlas` into its texture.
    pub fn upload(&self, atlas: &mut Atlas) {
        for (slot, rgba) in atlas.uploads.drain(..) {
            self.queue.write_texture(
                wgpu::TexelCopyTextureInfo {
                    texture: &self.atlas,
                    mip_level: 0,
                    origin: wgpu::Origin3d {
                        x: slot.x,
                        y: slot.y,
                        z: 0,
                    },
                    aspect: wgpu::TextureAspect::All,
                },
                &rgba,
                wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(slot.w * 4),
                    rows_per_image: None,
                },
                wgpu::Extent3d {
                    width: slot.w,
                    height: slot.h,
                    depth_or_array_layers: 1,
                },
            );
        }
    }

    /// Draws `scene` into `target`, `size` pixels.
    pub fn render(&mut self, target: &wgpu::TextureView, size: (u32, u32), scene: &Scene) {
        let screen = [size.0 as f32, size.1 as f32, 0.0, 0.0];
        self.queue
            .write_buffer(&self.screen, 0, bytemuck::cast_slice(&screen));
        // The images' quads go after the rest, those without a texture left out.
        let images: Vec<(&wgpu::BindGroup, Instance)> = scene
            .images
            .iter()
            .filter_map(|(id, quad)| Some((self.images.get(id)?, *quad)))
            .collect();
        let mut quads = scene.instances.clone();
        quads.extend(images.iter().map(|(_, quad)| *quad));
        if quads.len() > self.capacity {
            self.capacity = quads.len().next_power_of_two();
            self.quads = Self::quad_buffer(&self.device, self.capacity);
        }
        self.queue
            .write_buffer(&self.quads, 0, bytemuck::cast_slice(&quads));
        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("frame"),
            });
        {
            let [r, g, b, a] = scene.background.map(f64::from);
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("frame"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: target,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color { r, g, b, a }),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            pass.set_pipeline(&self.pipeline);
            pass.set_bind_group(0, &self.bind_group, &[]);
            pass.set_vertex_buffer(0, self.quads.slice(..));
            let first = u32::try_from(scene.instances.len()).unwrap_or(u32::MAX);
            pass.draw(0..4, 0..first);
            for (at, (group, _)) in (first..).zip(&images) {
                pass.set_bind_group(0, *group, &[]);
                pass.draw(0..4, at..at + 1);
            }
        }
        self.queue.submit([encoder.finish()]);
    }

    /// Draws `scene` into a new texture and reads it back as RGBA rows, for
    /// tests and screenshots.
    pub fn snapshot(&mut self, size: (u32, u32), scene: &Scene) -> Vec<u8> {
        let texture = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("snapshot"),
            size: wgpu::Extent3d {
                width: size.0,
                height: size.1,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });
        let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
        self.render(&view, size, scene);
        // Rows are copied out padded to 256 bytes.
        let padded = (size.0 * 4).div_ceil(256) * 256;
        let buffer = self
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("snapshot"),
                contents: &vec![0; (padded * size.1) as usize],
                usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            });
        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("copy"),
            });
        encoder.copy_texture_to_buffer(
            texture.as_image_copy(),
            wgpu::TexelCopyBufferInfo {
                buffer: &buffer,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(padded),
                    rows_per_image: None,
                },
            },
            texture.size(),
        );
        self.queue.submit([encoder.finish()]);
        let slice = buffer.slice(..);
        slice.map_async(wgpu::MapMode::Read, |_| {});
        let _ = self.device.poll(wgpu::PollType::wait_indefinitely());
        let data = slice.get_mapped_range().expect("mapped just now");
        let mut out = Vec::with_capacity((size.0 * size.1 * 4) as usize);
        for row in data.chunks(padded as usize) {
            out.extend_from_slice(&row[..(size.0 * 4) as usize]);
        }
        out
    }
}

/// The layout of what the pipeline reads: the screen's size, a texture and
/// its sampler.
fn bind_group_layout(device: &wgpu::Device) -> wgpu::BindGroupLayout {
    device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("greed"),
        entries: &[
            wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            },
            wgpu::BindGroupLayoutEntry {
                binding: 1,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: true },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            },
            wgpu::BindGroupLayoutEntry {
                binding: 2,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                count: None,
            },
        ],
    })
}

/// What the pipeline reads for a set of quads: the screen's size, and
/// `texture` sampled with `sampler`.
fn bind(
    device: &wgpu::Device,
    layout: &wgpu::BindGroupLayout,
    screen: &wgpu::Buffer,
    texture: &wgpu::Texture,
    sampler: &wgpu::Sampler,
) -> wgpu::BindGroup {
    let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
    device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("greed"),
        layout,
        entries: &[
            wgpu::BindGroupEntry {
                binding: 0,
                resource: screen.as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 1,
                resource: wgpu::BindingResource::TextureView(&view),
            },
            wgpu::BindGroupEntry {
                binding: 2,
                resource: wgpu::BindingResource::Sampler(sampler),
            },
        ],
    })
}

//! The macOS menu bar: the system's own, filled with the menus plugins set
//! (`require("@core").menus`). Choosing an item runs its command.

use std::sync::Mutex;

use greed_core::render::Menu;
use muda::accelerator::{Accelerator, Code, Modifiers};
use muda::{MenuEvent, MenuItem, PredefinedMenuItem, Submenu};
use winit::event_loop::EventLoopProxy;

use crate::window::Event;

/// The command of the menus' Quit item.
const QUIT: &str = "quit";

/// The command of the menus' New Window item, which cmd-n chooses.
const NEW_WINDOW: &str = "window-new";

/// The menu bar as last shown, kept so it's only built again when the
/// menus change.
pub struct MenuBar {
    shown: Option<Vec<Menu>>,
    /// The system holds on to the menu; this keeps its items alive too.
    menu: Option<muda::Menu>,
}

impl MenuBar {
    /// A menu bar whose items send the command they run to the event loop
    /// through `proxy`.
    pub fn new(proxy: EventLoopProxy<Event>) -> Self {
        let proxy = Mutex::new(proxy);
        MenuEvent::set_event_handler(Some(move |event: MenuEvent| {
            if let Ok(proxy) = proxy.lock() {
                let _ = proxy.send_event(Event::Menu(event.id.0));
            }
        }));
        MenuBar {
            shown: None,
            menu: None,
        }
    }

    /// Shows `menus`, after the application's own menu, if they changed.
    /// Quitting goes in the application's menu, as on any Mac app, not in
    /// the menu a plugin put it in.
    pub fn show(&mut self, menus: &[Menu]) {
        if self.shown.as_deref() == Some(menus) {
            return;
        }
        let menu = muda::Menu::new();
        let app = Submenu::new("Greed", true);
        let _ = app.append(&PredefinedMenuItem::services(None));
        let _ = app.append(&PredefinedMenuItem::separator());
        let _ = app.append(&PredefinedMenuItem::hide(None));
        let _ = app.append(&PredefinedMenuItem::hide_others(None));
        let _ = app.append(&PredefinedMenuItem::show_all(None));
        let quit = menus
            .iter()
            .flat_map(|m| &m.items)
            .find(|item| item.command == QUIT);
        if let Some(quit) = quit {
            let _ = app.append(&PredefinedMenuItem::separator());
            let accelerator = Accelerator::new(Some(Modifiers::SUPER), Code::KeyQ);
            let entry =
                MenuItem::with_id(quit.command.as_str(), "Quit Greed", true, Some(accelerator));
            let _ = app.append(&entry);
        }
        let _ = menu.append(&app);
        for m in menus {
            let submenu = Submenu::new(&m.title, true);
            for item in m.items.iter().filter(|item| item.command != QUIT) {
                // The item's id is its command, which choosing it runs.
                let accelerator = (item.command == NEW_WINDOW)
                    .then(|| Accelerator::new(Some(Modifiers::SUPER), Code::KeyN));
                let entry =
                    MenuItem::with_id(item.command.as_str(), &item.label, true, accelerator);
                let _ = submenu.append(&entry);
            }
            let _ = menu.append(&submenu);
        }
        menu.init_for_nsapp();
        self.menu = Some(menu);
        self.shown = Some(menus.to_vec());
    }
}

resource "hcloud_server" "node" {
  count       = 3
  name        = "shop-${count.index}"
  server_type = "cx32"
  image       = "ubuntu-24.04"
  location    = "hel1"
}

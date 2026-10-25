#!/usr/bin/env bash
# Records the demos, site/media/*.demo, as the window draws them, into
# target/media/NAME: NAME.mp4 when ffmpeg is here, the screenshots the demo
# takes, and its frames. `site/media/record.sh shell` records one. Needs a
# GPU, or software Vulkan like Mesa's lavapipe.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
media=$root/site/media
cargo build -q -p greed-editor -p greed-mail -p greed-matrix --manifest-path "$root/Cargo.toml"

# Starts a Dovecot in `$1` serving the sample mailbox, site/media/mail, as
# sam (any password), and writes the demo profile's mail.toml for it, for
# a demo saying `# needs: mail`. Prints Dovecot's pid. Dovecot comes from
# devenv, or GREED_MAIL_DOVECOT names one.
start_mail() {
  local dir=$1 profile=$2 port program
  program=${GREED_MAIL_DOVECOT:-$(command -v dovecot)}
  port=$((20000 + RANDOM % 40000))
  mkdir -p "$dir"/{run,state} "$dir"/home/sam/Maildir/{new,tmp}
  cp -r "$media/mail/cur" "$dir/home/sam/Maildir/cur"
  cat >"$dir/dovecot.conf" <<EOF
dovecot_config_version = 2.4.0
dovecot_storage_version = 2.4.0
base_dir = $dir/run
state_dir = $dir/state
log_path = $dir/log
instance_name = greed-demo-$port
default_internal_user = $(id -un)
default_internal_group = $(id -gn)
default_login_user = $(id -un)
protocols {
  imap = yes
}
listen = 127.0.0.1
ssl = no
auth_allow_cleartext = yes
service imap-login {
  chroot =
  inet_listener imap {
    port = $port
  }
  inet_listener imaps {
    port = 0
  }
}
service anvil {
  chroot =
}
passdb static {
  password = demo
}
userdb static {
  fields {
    uid = $(id -u)
    gid = $(id -g)
    home = $dir/home/%{user}
  }
}
mail_driver = maildir
mail_path = ~/Maildir
namespace inbox {
  inbox = yes
  separator = /
  mailbox Sent {
    special_use = \\Sent
    auto = create
  }
  mailbox Trash {
    special_use = \\Trash
    auto = create
  }
  mailbox Archive {
    special_use = \\Archive
    auto = create
  }
}
EOF
  cat >"$profile/config/mail.toml" <<EOF
[[account]]
name = "home"
address = "sam@example.com"
user = "sam"
imap = { host = "127.0.0.1", port = $port, tls = "none" }
password = ["echo", "demo"]
EOF
  "$program" -F -c "$dir/dovecot.conf" >/dev/null 2>&1 &
  echo $!
}

# Starts a Tuwunel in `$1` with made-up people and rooms for a demo saying
# `# needs: chat`: sam (password demo) is in the garden club, the ops room
# and a direct chat with Anna. Prints Tuwunel's pid and its address.
# Tuwunel comes from devenv, or GREED_MATRIX_TUWUNEL names one. Needs curl
# and jq.
start_chat() {
  local dir=$1 port program url pid
  program=${GREED_MATRIX_TUWUNEL:-$(command -v tuwunel)}
  port=$((20000 + RANDOM % 40000))
  url=http://127.0.0.1:$port
  mkdir -p "$dir"
  cat >"$dir/tuwunel.toml" <<EOF
[global]
server_name = "localhost"
database_path = "$dir/db"
address = ["127.0.0.1"]
port = $port
allow_registration = true
registration_token = "demo"
allow_federation = false
allow_check_for_updates = false
startup_netburst = false
log = "warn"
EOF
  "$program" -c "$dir/tuwunel.toml" >/dev/null 2>"$dir/log" &
  pid=$!
  until curl -sf "$url/_matrix/client/versions" >/dev/null; do sleep 0.1; done
  local -A token
  local user name session
  # The first account is the server's admin, with a room of its own: not
  # one of them.
  for user in admin:Admin sam:Sam anna:"Anna Berg" jonas:Jonas bea:"Bea Lind"; do
    name=${user#*:} user=${user%%:*}
    session=$(curl -s -XPOST "$url/_matrix/client/v3/register" \
      -d "{\"username\":\"$user\",\"password\":\"demo\"}" | jq -r .session)
    token[$user]=$(curl -s -XPOST "$url/_matrix/client/v3/register" \
      -d "{\"username\":\"$user\",\"password\":\"demo\",\"auth\":{\"type\":\"m.login.registration_token\",\"token\":\"demo\",\"session\":\"$session\"}}" |
      jq -r .access_token)
    curl -s -XPUT "$url/_matrix/client/v3/profile/@$user:localhost/displayname" \
      -H "Authorization: Bearer ${token[$user]}" -d "{\"displayname\":\"$name\"}" >/dev/null
  done
  local n=0
  # As `$1`, in the room `$2`, the message `$3`, and as HTML `$4` if given,
  # as clients send code.
  say() {
    n=$((n + 1))
    jq -n --arg body "$3" --arg html "${4:-}" '{msgtype: "m.text", body: $body}
      + if $html == "" then {} else {format: "org.matrix.custom.html", formatted_body: $html} end' |
      curl -s -XPUT "$url/_matrix/client/v3/rooms/$2/send/m.room.message/demo$n" \
        -H "Authorization: Bearer ${token[$1]}" -d @- >/dev/null
    sleep 0.05
  }
  # A room `$2` that `$1` makes, the others in `$3` joining it.
  room() {
    local id who
    id=$(curl -s -XPOST "$url/_matrix/client/v3/createRoom" -H "Authorization: Bearer ${token[$1]}" \
      -d "{\"name\":\"$2\",\"preset\":\"public_chat\"}" | jq -r .room_id)
    for who in $3; do
      curl -s -XPOST "$url/_matrix/client/v3/join/$id" \
        -H "Authorization: Bearer ${token[$who]}" -d '{}' >/dev/null
    done
    echo "$id"
  }
  local garden ops lunch
  ops=$(room jonas Ops "sam bea")
  say jonas "$ops" "The shop's deploy went out at 14:00"
  say bea "$ops" "Checkout looks fine from here"
  say jonas "$ops" "The worker pod restarted twice, I'm looking into it"
  local pods=$'NAME     READY   STATUS    RESTARTS\nworker   1/1     Running   2'
  say jonas "$ops" $'```\n'"$pods"$'\n```' "<pre><code>$pods</code></pre>"
  lunch=$(room anna "Anna Berg" "sam")
  say anna "$lunch" "Are we still on for lunch on Thursday?"
  garden=$(room anna "Garden club" "sam jonas bea")
  say bea "$garden" "Who's bringing the seed trays on Saturday?"
  say jonas "$garden" "I can, there's a stack of them in the shed"
  say anna "$garden" "The tomato seeds came today, enough for everyone"
  say bea "$garden" "Lovely! Which kinds?"
  say anna "$garden" "Sungold and San Marzano"
  say jonas "$garden" "Sam, could you bring the plant labels?"
  echo "$pid $url"
}

names=("$@")
if [ ${#names[@]} -eq 0 ]; then
  for demo in "$media"/*.demo; do
    names+=("$(basename "$demo" .demo)")
  done
fi

for name in "${names[@]}"; do
  # A fresh Greed in a folder of its own: the demo profile's config, and
  # the sample project to work on, shop, in the demo's home so paths show
  # as ~/shop.
  # Under /tmp, away from anything a folder above would load into the
  # shell, as a project's environment.
  scratch=$(mktemp -d -p /tmp greed-demo.XXXXXX)
  cp -r "$media/profile" "$scratch/profile"
  cp -r "$media/home" "$scratch/home"
  cp -r "$media/shop" "$scratch/home/shop"
  cp -r "$media/infra" "$scratch/home/infra"
  # Repositories, as real projects are: their root is the project's.
  for project in shop infra; do
    git -C "$scratch/home/$project" init -q -b main
    git -C "$scratch/home/$project" add -A
    git -C "$scratch/home/$project" -c user.name=demo -c user.email=demo@greed.rs \
      commit -q -m "$project"
  done
  cp "$media/$name.demo" "$scratch/"
  # The sample notes, ~/notes, only for a demo saying `# needs: notes`: in
  # the others, their agenda would show on the status line.
  if grep -q '^# needs: notes' "$media/$name.demo"; then
    cp -r "$media/notes" "$scratch/home/notes"
  fi
  servers=""
  if grep -q '^# needs: mail' "$media/$name.demo"; then
    servers=$(start_mail "$scratch/dovecot" "$scratch/profile")
  fi
  # The demo signs in to its Tuwunel, at the address `{matrix}` stands for.
  if grep -q '^# needs: chat' "$media/$name.demo"; then
    read -r tuwunel matrix <<<"$(start_chat "$scratch/tuwunel")"
    servers="$servers $tuwunel"
    sed -i "s|{matrix}|$matrix|g" "$scratch/$name.demo"
  fi
  echo "recording $name"
  # Nothing of this machine: a home of its own, and only the variables
  # programs and the GPU need. Its programs come first, like a kubectl with
  # a cluster of its own.
  vars=(HOME="$scratch/home" USER=demo SHELL="$(command -v bash)" LANG=C.UTF-8
    TERM=xterm-256color PATH="$scratch/home/shop/bin:$PATH")
  for var in LD_LIBRARY_PATH XDG_RUNTIME_DIR VK_ICD_FILENAMES VK_DRIVER_FILES; do
    if [ -n "${!var:-}" ]; then
      vars+=("$var=${!var}")
    fi
  done
  # What Greed is started with, from a demo's `# command: greed ARGS`
  # line, like `greed notes` for Hoard; nothing for the editor.
  read -ra args <<<"$(sed -n 's/^# command: greed //p' "$media/$name.demo")"
  (cd "$scratch/home/shop" && env -i "${vars[@]}" \
    "$root/target/debug/greed" --profile "$scratch/profile" --record "$scratch/$name.demo" \
    "${args[@]}")
  # The servers it started, Dovecot and Tuwunel.
  for server in $servers; do
    kill "$server" 2>/dev/null || true
    wait "$server" 2>/dev/null || true
  done
  out=$root/target/media/$name
  rm -rf "$out"
  mkdir -p "$(dirname "$out")"
  mv "$scratch/$name" "$out"
  rm -rf "$scratch"
  if command -v ffmpeg >/dev/null; then
    fps=$(awk '$1 == "fps" { print $2 }' "$media/$name.demo")
    ffmpeg -y -loglevel error -framerate "${fps:-30}" -i "$out/frames/%05d.png" \
      -c:v libx264 -pix_fmt yuv420p -crf 20 -movflags +faststart "$out/$name.mp4"
    echo "  $out/$name.mp4"
  else
    echo "  frames in $out/frames (no ffmpeg to make a video)"
  fi
done

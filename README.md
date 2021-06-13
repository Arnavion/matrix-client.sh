TUI [Matrix](https://matrix.org/) client in a single Bash script.


# Features

- `tmux` windows for rooms.
- Read-only.


# Dependencies

- `bash` - The script interpreter.
- `tmux` - The TUI framework.
- `curl`, `jq` - Communicating with the homeserver.
- `mkfifo`, `mktemp` - Communication between the `tmux` windows.
- `hostname`, `sha256sum`, `/etc/machine-id` - Used to derive the device ID and display name when logging in.


# Usage

```sh
./matrix-client.sh <user_id>
```

Example:

```sh
./matrix-client.sh '@arnavion:arnavion.dev'
```


# TODO

- Send events.
- Mark events as read on homeserver.
- Update events for redactions and replace.
- Custom mouse events to support scrolling into prev batch.


# License

```
matrix-client.sh

https://github.com/Arnavion/matrix-client.sh

Copyright 2021 Arnav Singh

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

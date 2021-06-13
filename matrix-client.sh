#!/bin/bash

# Ref:
#
# - https://matrix.org/docs/spec/
# - https://matrix.org/docs/spec/client_server/r0.6.1

set -euo pipefail

error() {
    >&2 cat
}

panic() {
    error
    exit 1
}

usage() {
    echo "Usage: $0 <user_id>"
    echo
    echo "Example: $0 '@arnavion:arnavion.dev'"
}

state_load() {
    local state
    state="$( (< "$state_path" jq --compact-output '.') 2>/dev/null || :)"
    if [ -z "$state" ]; then
        state='{}'
        > "$state_path" printf '%s' "$state"
    fi
    printf '%s' "$state"
}

state_patch() {
    > "$state_path" jq --compact-output --null-input --sort-keys \
        --argjson state "$(state_load)" \
        --argjson patch "$1" \
        '$state + $patch'
}

percent_encode() {
    local length="${#1}"

    for (( i = 0; i < length; i++ )); do
        local c="${1:$i:1}"
        printf '%%%02x' "'$c"
    done
}

parse_response() {
    response="$(cat)"
    if [ -z "$(<<< "$response" jq --raw-output '.errcode // empty')" ]; then
        <<< "$response" jq --compact-output '.'
    else
        <<< "$response" jq --exit-status --raw-output '"\(.errcode): \(.error)"' | error
    fi
}

get() {
    curl \
        -LsS \
        -H 'accept:application/json' \
        -H 'user-agent:matrix-client.sh' \
        "$1" |
        parse_response
}

post() {
    curl \
        -LsS \
        -H 'accept:application/json' \
        -H 'content-type:application/json' \
        -H 'user-agent:matrix-client.sh' \
        --data-raw "$2" \
        "$1" |
        parse_response
}

auth_get() {
    curl \
        -LsS \
        -H 'accept:application/json' \
        -H "authorization:Bearer $access_token" \
        -H 'user-agent:matrix-client.sh' \
        "$server_base_url$1" |
        parse_response
}

auth_post() {
    curl \
        -LsS \
        -H 'accept:application/json' \
        -H "authorization:Bearer $access_token" \
        -H 'content-type:application/json' \
        -H 'user-agent:matrix-client.sh' \
        --data-raw "$2" \
        "$server_base_url$1" |
        parse_response
}

get_server_base_url() {
    local server_name="${user_id#*:}"

    server_base_url="$(
        get "https://$server_name/.well-known/matrix/client" |
            jq --exit-status --raw-output '.["m.homeserver"].base_url'
    )"

    local supports_client_version
    supports_client_version="$(
        get "$server_base_url/_matrix/client/versions" |
            jq --exit-status --raw-output '.versions | any(. == "r0.6.0")'
        )"
    if [ "$supports_client_version" != 'true' ]; then
        <<< 'homeserver does not support r0.6.0 clients' panic
    fi
}

login() {
    access_token="$(state_load | jq --raw-output '.access_token // empty')"
    if [ -z "$access_token" ]; then
        local supports_password_login
        supports_password_login="$(
            get "$server_base_url/_matrix/client/r0/login" |
                jq --exit-status --raw-output '.flows | any(.type == "m.login.password")'
        )"
        if [ "$supports_password_login" != 'true' ]; then
            <<< 'homeserver does not support password login' panic
        fi

        local password

        while :; do
            tmux select-window -t "$TMUX_PANE"
            read -rsp 'Enter password: ' password
            echo

            local device_id
            device_id="matrix-client.sh:$(sha256sum /etc/machine-id | cut --delimiter ' ' --fields 1)"

            local login_response
            login_response="$(
                post "$server_base_url/_matrix/client/r0/login" "$(
                    jq --compact-output --null-input \
                        --arg device_id "$device_id" \
                        --arg hostname "$(hostname)" \
                        --arg user_id "$user_id" \
                        --arg password "$password" \
                        '{
                            "type": "m.login.password",
                            "identifier": {
                                "type": "m.id.user",
                                "user": $user_id,
                            },
                            "password": $password,
                            "device_id": $device_id,
                            "initial_device_display_name": "matrix-client.sh (\($hostname))",
                        }'
                )"
            )"
            if [ -n "$login_response" ]; then
                access_token="$(<<< "$login_response" jq --exit-status --raw-output '.access_token')"
                break
            fi
        done

        state_patch "$(
            jq --compact-output --null-input \
                --arg access_token "$access_token" \
                '{ "access_token": $access_token }'
        )"
    fi
}

print_multiline() {
    jq \
        --exit-status --null-input --raw-output \
        --arg text "$1" \
        '
            ($text | split("\n")) as $lines |
            if ($lines | length) > 1 then
                ">\($lines | map("\n           | \(.)") | join(""))"
            else
                $text
            end
        '
}

main() {
    local user_id="$1"

    # ShellCheck thinks the `\\'` indicates we're trying and failing to escape a `'`
    # shellcheck disable=SC1003
    printf '\e]2;%s\e\\' "$user_id"

    local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/matrix-client"
    mkdir -p "$config_dir"
    local state_path="$config_dir/$user_id.json"

    local server_base_url
    get_server_base_url

    local access_token
    login

    local sync_filter_id
    sync_filter_id="$(
        auth_post "/_matrix/client/r0/user/$(percent_encode "$user_id")/filter" "$(
            jq --compact-output --null-input '{
                "presence": {
                    "not_types": ["*"],
                },
                "room": {
                    "ephemeral": {
                        "not_types": ["*"],
                    },
                    "include_leave": true,
                    "state": {
                        "lazy_load_members": true,
                        "not_types": [
                            "m.reaction",
                            "m.room.avatar",
                            "m.room.member"
                        ],
                    },
                    "timeline": {
                        "lazy_load_members": true,
                        "not_types": [
                            "m.reaction",
                            "m.room.avatar",
                            "m.room.member"
                        ],
                    },
                },
            }'
        )" |
            jq --exit-status --raw-output '.filter_id'
    )"

    local sync_next_batch=''

    declare -A view_fds

    while :; do
        while :; do
            printf '\015Syncing at %s ... ' "$(date --iso-8601=seconds)"

            set +x
            local sync
            if [ -n "$sync_next_batch" ]; then
                sync="$(auth_get "/_matrix/client/r0/sync?filter=$sync_filter_id&since=$(percent_encode "$sync_next_batch")&timeout=10000")"
            else
                sync="$(auth_get "/_matrix/client/r0/sync?filter=$sync_filter_id")"
            fi
            if [ -n "${DEBUG:-}" ]; then
                set -x
            fi

            if [ -n "${DEBUG:-}" ]; then
                <<< "$sync" >sync.json jq '.'
            fi

            if [ -n "$sync" ]; then
                printf '\015Synced at %s      ' "$(date --iso-8601=seconds)"
                break
            fi

            state_patch '{ "access_token": "" }'

            <<< 'Reconnecting to homeserver...' error

            login
        done
        sync_next_batch="$(<<< "$sync" jq --exit-status --raw-output '.next_batch')"

        local line
        while read -r line; do
            local room_id
            room_id="$(<<< "$line" jq --exit-status --raw-output '.room_id')"
            local line
            line="$(<<< "$line" jq --compact-output --exit-status 'del(.room_id)')"

            local view_fd="${view_fds["$room_id"]:-}"
            if [ -z "$view_fd" ]; then
                local fifo_dir
                fifo_dir="$(mktemp --directory)"
                mkfifo "$fifo_dir/input" 2>/dev/null
                exec {view_fd}<>"$fifo_dir/input"
                rm -r "$fifo_dir"
                view_fds["$room_id"]="$view_fd"

                tmux new-window -d -e "DEBUG=${DEBUG:-}" "$0" view "$user_id" "$room_id" "/proc/$$/fd/$view_fd"
            fi

            >& "$view_fd" printf '%s\n' "$line"
        done < <(
            <<< "$sync" jq --compact-output --exit-status '
                . as $sync |
                    (
                        $sync.rooms.join |
                        to_entries |
                        map(
                            . as { key: $room_id, value: $room } |
                            { "room_id": $room_id, "summary": $room.summary }
                        )
                    ) +
                    (
                        (($sync.rooms.join | to_entries) + ($sync.rooms.leave | to_entries)) |
                            map(
                                . as { key: $room_id, value: $room } |
                                (
                                    ($room.state.events[], $room.timeline.events[]) |
                                    { "room_id": $room_id, "event": . }
                                )
                            )
                    ) |
                    sort_by(.event.origin_server_ts // 0)[]
            '
        )
    done
}

view() {
    local user_id="$1"
    local room_id="$2"
    local events_file="$3"

    local last_event_date=''

    local room_version=''

    local room_joined_member_count=0
    local room_invited_member_count=0
    local room_num_heroes=0
    local room_heroes=''

    local room_name=''
    local room_canonical_alias=''
    local room_display_name_changed='1'

    while :; do
        if [ -n "$room_display_name_changed" ]; then
            local room_display_name
            if [ -n "$room_canonical_alias" ]; then
                room_display_name="$room_canonical_alias"
            elif [ -n "$room_name" ]; then
                room_display_name="$room_name ($room_id)"
            elif (( room_num_heroes >= room_joined_member_count + room_invited_member_count - 1 )); then
                room_display_name="$room_heroes ($room_id)"
            else
                room_display_name="$room_id"
            fi
            # ShellCheck thinks the `\\'` indicates we're trying and failing to escape a `'`
            # shellcheck disable=SC1003
            printf '\e]2;%s\e\\' "$room_display_name"
            tmux rename-window -t "$TMUX_PANE" "$room_display_name"

            room_display_name_changed=''
        fi

        local line
        read -r line
        if [ -n "${DEBUG:-}" ]; then
            echo "$line"
        fi

        local summary
        summary="$(<<< "$line" jq --compact-output '.summary // empty')"
        local event
        event="$(<<< "$line" jq --compact-output '.event // empty')"

        if [ -n "$summary" ]; then
            room_joined_member_count="$(
                <<< "$summary" jq \
                    --exit-status --raw-output \
                    --arg current "$room_joined_member_count" \
                    '.["m.joined_member_count"] // $current'
            )"
            room_invited_member_count="$(
                <<< "$summary" jq \
                    --exit-status --raw-output \
                    --arg current "$room_invited_member_count" \
                    '.["m.invited_member_count"] // $current'
            )"
            room_num_heroes="$(
                <<< "$summary" jq \
                    --exit-status --raw-output \
                    --arg current "$room_num_heroes" \
                    '(.["m.heroes"] | length) // $current'
            )"
            room_heroes="$(
                <<< "$summary" jq \
                    --exit-status --raw-output \
                    --arg current "$room_heroes" \
                    '((.["m.heroes"] // empty) | sort | join(", ")) // $current'
            )"
            room_display_name_changed='1'
        elif [ -n "$event" ]; then
            local event_time
            event_time="$(<<< "$event" jq --exit-status --raw-output '.origin_server_ts / 1000')"

            local event_date
            event_date="$(date "--date=@$event_time" --iso-8601)"
            if [ -z "$last_event_date" ] || [ "$event_date" != "$last_event_date" ]; then
                if [ -n "$last_event_date" ]; then
                    echo
                fi
                printf -- '--- %s ---\n' "$event_date"
            fi
            last_event_date="$event_date"

            local line_prefix
            line_prefix="$(printf '[%s] ' "$(date "--date=@$event_time" '+%H:%M:%S')")"
            printf '%s' "$line_prefix"

            local event_type
            event_type="$(<<< "$event" jq --exit-status --raw-output '.type')"
            case "$event_type" in
                'm.room.canonical_alias')
                    room_canonical_alias="$(<<< "$event" jq --exit-status --raw-output '.content.alias')"
                    <<< "$event" jq \
                        --exit-status --raw-output \
                        --arg room_canonical_alias "$room_canonical_alias" \
                        '"\(.sender) set room canonical alias to \($room_canonical_alias)"'
                    room_display_name_changed='1'
                    ;;

                'm.room.create')
                    room_version="$(<<< "$event" jq --exit-status --raw-output '.content.room_version')"
                    <<< "$event" jq \
                        --exit-status --raw-output \
                        --arg room_version "$room_version" \
                        '"\(.content.creator) created room with version \($room_version)"'
                    ;;

                'm.room.encrypted')
                    <<< "$event" jq --exit-status --raw-output '"<\(.sender)> [encrypted message]"'
                    <<< "$event" jq --compact-output 'del(.event_id, .origin_server_ts, .sender, .type)'
                    ;;

                'm.room.guest_access')
                    <<< "$event" jq --exit-status --raw-output '"\(.sender) set room guest access to \(.content.guest_access)"'
                    ;;

                'm.room.history_visibility')
                    <<< "$event" jq --exit-status --raw-output '"\(.sender) set room history visibility to \(.content.history_visibility)"'
                    ;;

                'm.room.join_rules')
                    <<< "$event" jq --exit-status --raw-output '"\(.sender) set room join rules to \(.content.join_rule)"'
                    ;;

                'm.room.message')
                    case "$(<<< "$event" jq --exit-status --raw-output '.content.msgtype // ""')" in
                        'm.image')
                            <<< "$event" jq --exit-status --raw-output '"\(.sender) posted image \(.content.body) \(.content.url)"'
                            ;;

                        'm.text')
                            local pretty_printed
                            pretty_printed="$(print_multiline "$(<<< "$event" jq --exit-status --raw-output '.content.body')")"
                            <<< "$event" jq --exit-status --raw-output --arg pretty_printed "$pretty_printed" '"<\(.sender)> \($pretty_printed)"'
                            if [ -n "$(<<< "$event" jq '.content["m.relates_to"] // empty' || :)" ]; then
                                if [ -z "$(<<< "$event" jq '.content["m.relates_to"]["m.in_reply_to"] // empty' || :)" ]; then
                                    <<< "$event" jq --compact-output --exit-status '.content'
                                fi
                            fi
                            ;;

                        *)
                            printf '%s' "$(<<< "$event" jq --exit-status --raw-output '"<\(.sender)> "')"
                            <<< "$event" jq --compact-output 'del(.event_id, .origin_server_ts, .sender, .type)'
                            ;;
                    esac
                    ;;

                'm.room.name')
                    room_name="$(<<< "$event" jq --exit-status --raw-output '.content.name')"
                    <<< "$event" jq \
                        --exit-status --raw-output \
                        --arg room_name "$room_name" \
                        '"\(.sender) set room name to \($room_name)"'
                    room_display_name_changed='1'
                    ;;

                'm.room.power_levels')
                    <<< "$event" jq \
                        --exit-status --raw-output \
                        '
                            "\(.sender) set room power levels: \(
                                .content.users |
                                    to_entries |
                                    group_by(.value) |
                                    map({ level: .[0].value, users: map(.key) }) |
                                    sort_by(-.level) |
                                    map("\(.level): \(.users | sort | join(", "))") |
                                    join("; ")
                            )"
                        '
                    ;;

                'm.room.related_groups')
                    <<< "$event" jq --exit-status --raw-output '"\(.sender) set room related groups to \(.content.groups | join(", "))"'
                    ;;

                'm.room.topic')
                    local pretty_printed
                    pretty_printed="$(print_multiline "$(<<< "$event" jq --exit-status --raw-output '.content.topic')")"
                    <<< "$event" jq --exit-status --raw-output --arg pretty_printed "$pretty_printed" '"\(.sender) set room topic to \($pretty_printed)"'
                    ;;

                *)
                    printf '%s ' "$(<<< "$event" jq --raw-output '"\(.sender) \(.type)"')"
                    <<< "$event" jq --compact-output 'del(.event_id, .origin_server_ts, .sender, .type)'
                    ;;
            esac
        else
            <<< 'unrecognized line from main' error
            <<< "$line" jq --compact-output '.' | panic
        fi
    done < "$events_file"
}

if [ -n "${DEBUG:-}" ]; then
    set -x
fi

case "${1:-}" in
    'main')
        main "${@:2}"
        ;;

    'view')
        view "${@:2}"
        ;;

    '@'*)
        user_id="$1"

        exec tmux new-session -s 'matrix-client' -n "$user_id" -e "DEBUG=${DEBUG:-}" "$0" main "$user_id"
        ;;

    '--help')
        usage
        ;;

    *)
        usage | panic
        ;;
esac

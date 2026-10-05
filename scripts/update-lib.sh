#!/bin/zsh

arqmeter_validate_bundle() {
    local bundle_path=$1
    local executable_path="$bundle_path/Contents/MacOS/Arqmeter"
    local info_path="$bundle_path/Contents/Info.plist"

    [[ -d "$bundle_path" ]] || return 1
    [[ -x "$executable_path" ]] || return 1
    /usr/bin/plutil -lint "$info_path" >/dev/null || return 1
    /usr/bin/codesign --verify --deep --strict "$bundle_path" >/dev/null 2>&1 || return 1
}

arqmeter_binary_hash() {
    local bundle_path=$1
    /usr/bin/shasum -a 256 "$bundle_path/Contents/MacOS/Arqmeter" | /usr/bin/awk '{print $1}'
}

arqmeter_launchagent_healthy() {
    local launchctl_bin=$1
    local service_name=$2
    local attempts=$3
    local delay_seconds=$4
    local required_stable_samples=$5
    local output state pid runs
    local previous_pid=""
    local previous_runs=""
    local stable_samples=0
    local observed_running=0
    local attempt=1

    while (( attempt <= attempts )); do
        if output=$("$launchctl_bin" print "$service_name" 2>/dev/null); then
            state=$(print -r -- "$output" | /usr/bin/awk '$1 == "state" && $2 == "=" {print $3; exit}')
            pid=$(print -r -- "$output" | /usr/bin/awk '$1 == "pid" && $2 == "=" {print $3; exit}')
            runs=$(print -r -- "$output" | /usr/bin/awk '$1 == "runs" && $2 == "=" {print $3; exit}')

            if [[ "$state" == "running" && "$pid" == <-> && "$runs" == <-> ]] && /bin/kill -0 "$pid" 2>/dev/null; then
                if (( observed_running )) && [[ "$pid" != "$previous_pid" || "$runs" != "$previous_runs" ]]; then
                    return 1
                fi
                observed_running=1
                if [[ "$pid" == "$previous_pid" && "$runs" == "$previous_runs" ]]; then
                    (( stable_samples += 1 ))
                    (( stable_samples >= required_stable_samples )) && return 0
                fi
                previous_pid=$pid
                previous_runs=$runs
            elif (( observed_running )); then
                return 1
            fi
        elif (( observed_running )); then
            return 1
        fi

        (( attempt += 1 ))
        (( attempt <= attempts )) && /bin/sleep "$delay_seconds"
    done

    return 1
}

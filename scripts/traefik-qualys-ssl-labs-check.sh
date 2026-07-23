#!/bin/bash
. /etc/bash/gaboshlib.include
g_lockfile
g_nice
g_all-to-syslog
g_echo_ok "Starting $0"

# Using official ssllabs-scan API client
# https://www.ssllabs.com/projects/ssllabs-apis/
# https://github.com/ssllabs/ssllabs-scan/

# Download and build ssllabs-scan if not already installed
if ! [ -f /usr/local/bin/ssllabs-scan ]
then
  cd /tmp
  rm -rf ssllabs-scan
  # Clone the ssllabs-scan repository
  if ! git clone https://github.com/ssllabs/ssllabs-scan/
  then
    g_echo_error "Could not download ssllabs-scan"
  else
    cd ssllabs-scan
    make >"${g_tmp}/ssllabs-scan-make.out"
    if [ -f ssllabs-scan-v3 ]
    then
      cp ssllabs-scan-v3 /usr/local/bin/ssllabs-scan
      chmod 755 /usr/local/bin/ssllabs-scan
      chown root. /usr/local/bin/ssllabs-scan
    else
      g_echo_error "Could not build ssllabs-scan $(cat ${g_tmp}/ssllabs-scan-make.out)"
    fi
  fi
fi

# Scan every Traefik-hosted service
if [ -f /usr/local/bin/ssllabs-scan ]
then
  # Collect all hostnames from docker-compose files
  find /home/docker -maxdepth 1 -mindepth 1 -type d | grep -E -v "\.del$|\.bak$|\.old$|var-lib-docker$" | while read g_dir
  do
    if grep -q Host "$g_dir"/docker-compose.override.yml >/dev/null 2>&1
    then
      grep Host "$g_dir"/docker-compose.override.yml >>"$g_tmp/hosts"
    else
      if [ -f "$g_dir"/docker-compose.yml ]
      then
        grep Host "$g_dir"/docker-compose.yml >>"$g_tmp/hosts"
      fi
    fi
  done
  grep Host /home/docker/traefik/providers/*.yml >>"$g_tmp/hosts"

  # Iterate over unique hostnames and run ssllabs-scan
  cat "$g_tmp/hosts" | cut -d '`' -f2 | sort -u | while read g_host
  do
    g_resultfile="/tmp/ssllabs-scan-result-$$-$g_host"

    # Skip if host is not resolvable
    if ! host "${g_host}" >/dev/null 2>&1
    then
      continue
    fi
    # Skip if host does not respond to HTTPS
    if ! curl -s "https://${g_host}" >/dev/null 2>&1
    then
      continue
    fi

    # Initialize result file with empty JSON array
    echo '[]' >"$g_resultfile"

    # Poll until ssllabs-scan returns a non-empty result
    while cat "$g_resultfile" | jq -r | grep -E -q '^\[\]$'
    do
      until ssllabs-scan --quiet "${g_host}" >"$g_resultfile"
      do
        sleep 60
      done
      sleep 60
    done

    # Extract grade for each endpoint
    cat "$g_resultfile" | jq '.[] | .endpoints | .[] | .grade' >"${g_tmp}/ssllabs-scan-result" 2>&1 >"${g_tmp}/ssllabs-scan-result"

    # Report grade; warn if not A+
    if ! grep -E -q 'A+|null' "${g_tmp}/ssllabs-scan-result"
    then
      g_echo_error "Qualys SSL Labs scan-result for ${g_host} not A+: $(cat ${g_tmp}/ssllabs-scan-result)

https://www.ssllabs.com/ssltest/analyze.html?d=${g_host}&hideResults=on

Result: $(cat ${g_tmp}/ssllabs-scan-result)"
    else
      g_echo_ok "Qualys SSL Labs scan-result for ${g_host}: $(cat ${g_tmp}/ssllabs-scan-result)"
    fi
    rm "$g_resultfile"
  done
fi

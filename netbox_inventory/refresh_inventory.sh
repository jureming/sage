#!/usr/bin/env bash
set -Eeuo pipefail

source /root/.netbox/secrets.sh

base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

limit=1000
host_name=$(hostname -s 2>/dev/null || hostname)
host_name=${host_name%%.*}

# 최종 파일과 같은 파일시스템에 임시 디렉터리 생성
tmp_dir=$(mktemp -d "$base_dir/.netbox_list.tmp.XXXXXX")
trap 'rm -rf -- "$tmp_dir"' EXIT

vm_tmp="$tmp_dir/vm_inventory"
devices_total_tmp="$tmp_dir/device_inventory_total"

# ==============================================================================
# VM 조회
#
# 출력 순서:
# 이름 / Role / Zone / OS / Service-unit /
# 외부망 / 내부망 / Primary IPv4 / Primary IPv6
# ==============================================================================

: > "$vm_tmp"
offset=0

while true; do
    curl_args=(
        curl
        -fsS
        --get
        --connect-timeout 5
        --max-time 60
        -H "Authorization: Token ${NETBOX_TOKEN}"
        -H "Accept: application/json"
        --data-urlencode "status!=offline"
        --data-urlencode "ordering=name"
        --data-urlencode "limit=${limit}"
        --data-urlencode "offset=${offset}"
    )

    curl_args+=(
        "${NETBOX_URL%/}/api/virtualization/virtual-machines/"
    )

    response=$("${curl_args[@]}")

	jq -r '
		 def value_or_x:
        if . == null or . == "" then
            "N/A"
        else
            .
        end;

		def ip_or_na:
        if type == "string" and . != "" then
            split("/")[0]
        else
            "N/A"
        end;

	    .results[]
	    | [
	        (.name | value_or_x),
	        (.role.name | value_or_x),
	        (.custom_fields.zone | value_or_x),
	        (.platform.name | value_or_x),
	       	(.custom_fields.service_unit | value_or_x),
			(.custom_fields.ip_internal | value_or_x),
			(.custom_fields.ip_external | value_or_x),
			(.primary_ip4.address? | ip_or_na),
			(.primary_ip6.address? | ip_or_na)
			]
	    | @tsv
	' <<< "$response" >> "$vm_tmp"

    total=$(jq -r '.count' <<< "$response")
    returned=$(jq -r '.results | length' <<< "$response")

    offset=$((offset + returned))

    if (( returned == 0 || offset >= total )); then
        break
    fi
done

# 조회가 끝난 완성본으로 교체
mv -f -- "$vm_tmp" $base_dir/vm_inventory

# ==============================================================================
# Device 조회
#
# 출력 순서:
# 이름 / Role / OS /
# 외부망 / 내부망 / Primary IPv4 / Primary IPv6
# ==============================================================================
    : > "$devices_total_tmp"
    offset=0

    while true; do
        response=$(
            curl -fsS \
                --get \
                --connect-timeout 5 \
                --max-time 60 \
                -H "Authorization: Token ${NETBOX_TOKEN}" \
                -H "Accept: application/json" \
                --data-urlencode "status!=offline" \
                --data-urlencode "ordering=name" \
                --data-urlencode "limit=${limit}" \
                --data-urlencode "offset=${offset}" \
                "${NETBOX_URL%/}/api/dcim/devices/"
        )

		jq -r '
			 def value_or_x:
				if . == null or . == "" then
				    "N/A"
				else
				    .
				end;

			def ip_or_na:
				if type == "string" and . != "" then
					split("/")[0]
				else
					"N/A"
				end;

		    .results[]
		    | [
		        (.name | value_or_x),
		        (.role.name | value_or_x),
		        (.platform.name | value_or_x),
				(.custom_fields.ip_internal | value_or_x),
				(.custom_fields.ip_external | value_or_x),
				(.primary_ip4.address? | ip_or_na),
				(.primary_ip6.address? | ip_or_na)
			]
		    | @tsv
		' <<< "$response" >> "$devices_total_tmp"

        total=$(jq -r '.count' <<< "$response")
        returned=$(jq -r '.results | length' <<< "$response")

        offset=$((offset + returned))

        if (( returned == 0 || offset >= total )); then
            break
        fi
    done

# 조회가 끝난 완성본으로 교체
mv -f -- "$devices_total_tmp" $base_dir/device_inventory

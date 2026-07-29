#!/bin/bash

home_dir="$(cd "$(dirname "$0")" && pwd)"
vm_inventory="$home_dir/vm_inventory"

salt_dir='/srv/salt'

[ -s "$vm_inventory" ] || {
    echo "vm_inventory 파일이 없거나 비어 있습니다: $vm_inventory" >&2
    exit 1
}

mkdir -p "/srv/pillar/minions"
echo -e "{% set safeid = grains['id'] | regex_replace('[^A-Za-z0-9_-]', '_') %}\n\nbase:\n  '*':\n    - minions._default\n    - netbox\n    - minions.{{ safeid }}" > /srv/pillar/top.sls
echo -e "netbox:\n  NETBOX_URL: \"$NETBOX_URL\"\n  NETBOX_TOKEN: \"$NETBOX_TOKEN\"" > /srv/pillar/netbox.sls
echo -e "site: \"kt\"\nzone: \"prod-corp\"\ntemplate_name: \"default\"\nrsync_host: \"salt01.in.mailplug.co.kr:10873\"" > /srv/pillar/minions/_default.sls

while IFS=$'\t' read -r host role zone platform service_unit ip_internal ip_external ip4_address ip6_address site cluster vm_zone backup_run backup_host deploy_exception template_name; do
	[ -n "$host" ] || continue

	pillar_file="/srv/pillar/minions/${host}.sls"
    if [ "$zone" == "test-cert" ]; then
        rsync_host="172.17.11.31:10873"
    elif [ "$zone" == "test-corp" ]; then
        rsync_host="172.17.2.151:10873"
    elif [ "$zone" == "devs-corp" ]; then
        rsync_host="172.17.3.251:10873"
    elif [ "$zone" == "demo-corp" ]; then
        rsync_host="172.17.1.150:10873"
    elif [ "$zone" == "ucloud" ]; then
        rsync_host="121.156.118.114:10873"
    elif [ "$site" == "hw" ]; then
        rsync_host="121.156.118.114:10873"
    elif [ "$zone" == "prod-ncrt" ]; then
        rsync_host="121.156.118.114:10873"
    elif [ "$zone" == "prod-cert" ]; then
        rsync_host="10.1.79.245:10873"
    else
        rsync_host="salt01.in.mailplug.co.kr:10873"
    fi
	printf 'site: "%s"\n' "$site" > "$pillar_file"
	printf 'zone: "%s"\n' "$zone" >> "$pillar_file"
	printf 'template_name: "%s"\n' "$template_name" >> "$pillar_file"
	printf 'rsync_host: "%s"\n' "$rsync_host" >> "$pillar_file"

done < "$vm_inventory"

#cat /srv/pillar/minions/mypage02-test2.sls

#파일 만들거나 수정 후 Pillar 갱신
#salt '*' -b 200 saltutil.refresh_pillar

#확인
#salt 'cmail01' pillar.items
#salt 'ma79' pillar.items site

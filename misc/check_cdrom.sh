for vm_name in $(acli vm.list --power_state=kOn | awk 'NR>1 {print $1}'); do
  disk_info=$(acli vm.disk_get "$vm_name")
  if echo "$disk_info" | grep -q "cdrom: True"; then
    if ! echo "$disk_info" | grep -q "empty: True"; then
      iso_path=$(echo "$disk_info" | grep "source_nfs_path" | awk '{print $2}')
      echo "VM: $vm_name is mounted with ISO: $iso_path"
    fi
  fi
done

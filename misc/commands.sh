for i in `acli vm.list | awk '{print $1}' | sed '1d'`; do acli vm.disk_get $i | awk '{print}' ORS=' '| grep cdrom | grep -Evq 'empty' && echo $i has a cdrom mounted; done

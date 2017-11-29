#! /bin/bash
{ echo instance-id: iid-local01; echo local-hostname: f22-cloud; } > meta-data
$ printf "#cloud-config\npassword: fedora\nchpasswd: { expire: False }\nssh_pwauth: True\n" > user-data
$ genisoimage  -output seed.iso -volid cidata -joliet -rock user-data meta-data


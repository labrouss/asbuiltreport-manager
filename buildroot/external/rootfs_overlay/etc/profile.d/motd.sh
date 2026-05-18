#!/bin/sh
IP=$(ip -4 addr show scope global 2>/dev/null | grep -oE 'inet [0-9.]+' | head -1 | cut -d' ' -f2)
IP="${IP:-<not yet assigned>}"
cat << EOF

  ╔═══════════════════════════════════════════════════════════════╗
  ║         AsBuiltReport Manager Appliance                      ║
  ╠═══════════════════════════════════════════════════════════════╣
  ║                                                               ║
  ║  Web UI:      http://${IP}:3001
  ║  Web Console: https://${IP}:8443  (browser terminal)
  ║  SSH:         ssh root@${IP}
  ║                                                               ║
  ║  Edit boot:   mount /dev/sda1 /boot/efi                      ║
  ║               vi /boot/efi/EFI/BOOT/grub.cfg                 ║
  ║                                                               ║
  ╚═══════════════════════════════════════════════════════════════╝

EOF

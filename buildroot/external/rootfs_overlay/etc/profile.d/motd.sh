#!/bin/sh
# Show current IP in the welcome message at each login
IP=$(ip -4 addr show scope global 2>/dev/null | grep -oE 'inet [0-9.]+' | head -1 | cut -d' ' -f2)
IP="${IP:-not yet assigned}"
cat << EOF

  ╔═══════════════════════════════════════════════════════════════╗
  ║         AsBuiltReport Manager Appliance                      ║
  ╠═══════════════════════════════════════════════════════════════╣
  ║                                                               ║
  ║  Web UI:      http://${IP}:3001
  ║  Console:     abr-console                                    ║
  ║  Docker logs: docker logs asbuiltreport-app -f               ║
  ║                                                               ║
  ╚═══════════════════════════════════════════════════════════════╝

EOF

################################################################################
#
# asbuiltreport-manager
#
# Installs the Docker Compose stack, pre-saved Docker images, systemd units,
# management TUI console, and first-boot scripts into the root filesystem.
#
################################################################################

ASBUILTREPORT_MANAGER_VERSION = 1.0.0
ASBUILTREPORT_MANAGER_SITE    = $(BR2_EXTERNAL_ASBUILTREPORT_MANAGER_PATH)/package/asbuiltreport-manager
ASBUILTREPORT_MANAGER_SITE_METHOD = local
ASBUILTREPORT_MANAGER_LICENSE = MIT

# ── Nothing to build — this is a data/script-only package ────────────────────
define ASBUILTREPORT_MANAGER_BUILD_CMDS
endef

# ── Install the docker-images tarball placeholder + compose file ─────────────
# The actual docker images (docker save output) are injected during the
# post-build step by board/asbuiltreport-manager/post-build.sh
define ASBUILTREPORT_MANAGER_INSTALL_TARGET_CMDS
    # Bind-mount host directories (created at runtime by first-boot)
    $(INSTALL) -d -m 0755 $(TARGET_DIR)/var/www/reports
    $(INSTALL) -d -m 0755 $(TARGET_DIR)/etc/asbuiltreport
    $(INSTALL) -d -m 0755 $(TARGET_DIR)/var/lib/asbuiltreport/ps-modules
    # Staging area for pre-loaded docker images
    $(INSTALL) -d -m 0755 $(TARGET_DIR)/var/lib/docker-preload
endef

$(eval $(generic-package))

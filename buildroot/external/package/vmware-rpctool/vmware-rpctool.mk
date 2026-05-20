################################################################################
#
# vmware-rpctool — minimal VMware GuestInfo reader using backdoor port
# Replaces open-vm-tools for musl-based builds
#
################################################################################

VMWARE_RPCTOOL_VERSION = 1.1
VMWARE_RPCTOOL_SITE = $(BR2_EXTERNAL_ASBUILTREPORT_MANAGER_PATH)/package/vmware-rpctool
VMWARE_RPCTOOL_SITE_METHOD = local

define VMWARE_RPCTOOL_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-o $(@D)/vmware-rpctool $(@D)/vmware-rpctool.c
endef

define VMWARE_RPCTOOL_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/vmware-rpctool \
		$(TARGET_DIR)/usr/bin/vmware-rpctool
endef

$(eval $(generic-package))

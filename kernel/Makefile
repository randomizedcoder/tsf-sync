obj-m += tsf_ptp.o

KDIR ?= /lib/modules/$(shell uname -r)/build

# mac80211 internal headers (ieee80211_i.h) are needed for struct
# ieee80211_local, IEEE80211_DEV_TO_SUB_IF, vif_to_sdata, etc.
# This requires building against a full kernel source tree.
#
# On NixOS, the source tree is at $(KDIR)/../source/
# On standard distros, the source is typically at $(KDIR) itself.
KSRC := $(shell if [ -d "$(KDIR)/../source/net/mac80211" ]; then \
	echo "$(KDIR)/../source"; \
	elif [ -d "$(KDIR)/net/mac80211" ]; then \
	echo "$(KDIR)"; \
	else echo "$(KDIR)"; fi)

ccflags-y += -I$(KSRC)/net/mac80211

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install:
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install

.PHONY: all clean install


# Set IOS_NED to a directory with the unpacked Cisco IOS NED
#
# Or simply invoke the make with it's location, for example:
#
#   make IOS_NED=/tmp/cisco-ios-cli-6.45
#
IOS_NED ?= /opt/ncs/packages/cisco-ios-cli-6.45


all: ncs-runtime

# Setup a symlink to the NED
cisco-ios-cli:
	@if [ ! -e "$(IOS_NED)"/package-meta-data.xml ]; then \
	  echo "Can't find IOS NED at $(IOS_NED)" ; exit 1 ; \
	fi
	rm -f ./$@
	ln -s "$(IOS_NED)" ./$@

# Create a NETSIM directory with two IOS devices called ios0 and ios1
netsim: cisco-ios-cli
	rm -rf ./$@
	ncs-netsim --dir ./$@ create-network $< 2 ios

# Create an NSO runtime directory
ncs-runtime: netsim
	rm -rf ./$@
	@echo "Creating NSO runtime dir in ./$@"
	ncs-setup --dest ./$@
	@echo "Adding debug hide-group to ncs.conf"
	@perl -pi -e 'if (/NCS can be configured/) { print "  <hide-group><name>debug</name></hide-group>\n\n"; }' ./$@/ncs.conf
	@echo "Enabling audit-network-log in ncs.conf"
	@perl -pi -e 'if (/<netconf-log>/) { print "  <audit-network-log><enabled>true</enabled><file><name>./logs/audit-network.log</name><enabled>true</enabled></file></audit-network-log>\n\n"; }' ./$@/ncs.conf
	@echo "Disabling rollback in ncs.conf"
	@perl -ni -e 'if (defined $$p && /enabled/) { s/true/false/; undef $$p; print; } elsif (/<rollback>/) { print; $$p=1; } else { print; }' ./$@/ncs.conf
	@: # Setup packages (if any)
	@if [ -e ./$@/packages ]; then				\
	    cd ./$@/packages && ln -s ../../packages/* . ;	\
	fi || true


clean:
	$(MAKE) -k stop > /dev/null 2>&1 || true
	rm -rf ./netsim ./ncs-runtime
	rm -f  ./cisco-ios-cli


reset:
	ncs-netsim --dir ./netsim reset
	ncs --stop || true
	ncs-setup --dest ./ncs-runtime reset

start:
	ncs-netsim --dir ./netsim start
	cd ./ncs-runtime && ncs

cli:
	ncs_cli -u admin -g admin -C

stop:
	ncs-netsim stop || true
	ncs --stop || true


# Show current progress trace configuration
show:
	@ncs_load -FC -p /progress

enable:
	@sh ./enable-trace.sh

disable:
	@sh ./disable-trace.sh

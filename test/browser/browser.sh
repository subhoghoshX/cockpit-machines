#!/bin/sh
set -eux

# like "basic", passed on to run-test.sh
PLAN="$1"

export TEST_BROWSER=${TEST_BROWSER:-firefox}

TESTS="$(realpath $(dirname "$0"))"
export SOURCE="$(realpath $TESTS/../..)"

# https://tmt.readthedocs.io/en/stable/overview.html#variables
export LOGS="${TMT_TEST_DATA:-$(pwd)/logs}"
mkdir -p "$LOGS"
chmod a+w "$LOGS"

# we don't need the H.264 codec, and it is sometimes not available (rhbz#2005760)
DNF="dnf install --disablerepo=fedora-cisco-openh264 -y"

# install firefox (available everywhere in Fedora and RHEL)
# we don't need the H.264 codec, and it is sometimes not available (rhbz#2005760)
$DNF --setopt=install_weak_deps=False firefox

# nodejs 10 is too old for current Cockpit test API
if grep -q platform:el8 /etc/os-release; then
    dnf module switch-to -y nodejs:16
fi

# RHEL/CentOS 8 and Fedora have this, but not RHEL 9; tests check this more precisely
$DNF libvirt-daemon-driver-storage-iscsi-direct || true

#HACK: unbreak rhel-9-0's default choice of 999999999 rounds, see https://bugzilla.redhat.com/show_bug.cgi?id=1993919
sed -ie 's/#SHA_CRYPT_MAX_ROUNDS 5000/SHA_CRYPT_MAX_ROUNDS 5000/' /etc/login.defs

# Show critical packages versions
rpm -q selinux-policy cockpit-bridge cockpit-machines
rpm -qa | grep -E 'libvirt|qemu' | sort

# create user account for logging in
if ! id admin 2>/dev/null; then
    useradd -c Administrator -G wheel admin
    echo admin:foobar | chpasswd
fi

# set root's password
echo root:foobar | chpasswd

# avoid sudo lecture during tests
su -c 'echo foobar | sudo --stdin whoami' - admin

# create user account for running the test
if ! id runtest 2>/dev/null; then
    useradd -c 'Test runner' runtest
    # allow test to set up things on the machine
    mkdir -p /root/.ssh
    curl https://raw.githubusercontent.com/cockpit-project/bots/main/machine/identity.pub  >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
fi
chown -R runtest "$SOURCE"

# disable core dumps, we rather investigate them upstream where test VMs are accessible
echo core > /proc/sys/kernel/core_pattern

systemctl enable --now cockpit.socket

# make sure that we can access cockpit through the firewall
systemctl start firewalld
firewall-cmd --add-service=cockpit --permanent
firewall-cmd --add-service=cockpit

. /usr/lib/os-release

if [ "${PLATFORM_ID:-}" != "platform:el8" ]; then
    # https://gitlab.com/libvirt/libvirt/-/issues/219
    systemctl start virtinterfaced.socket
    systemctl start virtnetworkd.socket
    systemctl start virtnodedevd.socket
    systemctl start virtstoraged.socket
fi

# Fedora split out qemu-virtiofsd
if [ "$ID" = fedora ]; then
    dnf install -y virtiofsd
fi

# Run tests as unprivileged user
# once we drop support for RHEL 8, use this:
# runuser -u runtest --whitelist-environment=TEST_BROWSER,TEST_ALLOW_JOURNAL_MESSAGES,TEST_AUDIT_NO_SELINUX,SOURCE,LOGS $TESTS/run-test.sh $PLAN
runuser -u runtest --preserve-environment env USER=runtest HOME=$(getent passwd runtest | cut -f6 -d:) $TESTS/run-test.sh $PLAN

RC=$(cat $LOGS/exitcode)
exit ${RC:-1}

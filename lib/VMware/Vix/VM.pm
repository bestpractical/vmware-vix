package VMware::Vix::VM;
use VMware::Vix::Simple;
use VMware::Vix::API::Constants;
use Scalar::Util qw/dualvar/;
use Carp;

our %PROPERTY;
our %POWERSTATE;

our %MOUNTS;
our %CONFIG;

BEGIN {
    %PROPERTY = (
        cpus          => VIX_PROPERTY_VM_NUM_VCPUS,
        features      => VIX_PROPERTY_VM_SUPPORTED_FEATURES,
        is_recording  => VIX_PROPERTY_VM_IS_RECORDING,
        is_replaing   => VIX_PROPERTY_VM_IS_REPLAYING,
        is_running    => VIX_PROPERTY_VM_IS_RUNNING,
        memory_size   => VIX_PROPERTY_VM_MEMORY_SIZE,
        pathname      => VIX_PROPERTY_VM_VMX_PATHNAME,
        power_state   => VIX_PROPERTY_VM_POWER_STATE,
        read_only     => VIX_PROPERTY_VM_READ_ONLY,
        in_vmteam     => VIX_PROPERTY_VM_IN_VMTEAM,
        team_pathname => VIX_PROPERTY_VM_VMTEAM_PATHNAME,
        tools_state   => VIX_PROPERTY_VM_TOOLS_STATE,
    );

    %POWERSTATE = (
        VIX_POWERSTATE_POWERING_OFF()   => "powering off",
        VIX_POWERSTATE_POWERED_OFF()    => "powered off",
        VIX_POWERSTATE_POWERING_ON()    => "powering on",
        VIX_POWERSTATE_POWERED_ON()     => "powered on",
        VIX_POWERSTATE_SUSPENDING()     => "suspending",
        VIX_POWERSTATE_SUSPENDED()      => "suspended",
        VIX_POWERSTATE_TOOLS_RUNNING()  => "tools running",
        VIX_POWERSTATE_RESETTING()      => "resetting",
        VIX_POWERSTATE_BLOCKED_ON_MSG() => "blocked on message",
        VIX_POWERSTATE_PAUSED()         => "paused",
#       0x0400                          ,  "??",
        VIX_POWERSTATE_RESUMING()       => "resuming",
    );
}

sub new {
    my $class = shift;
    my %args  = @_;
    croak "No host given"
        unless $args{host} and $args{host}->isa("VMware::Vix::Host");
    if ( $args{image} ) {
    } elsif ( $args{store} and ( $args{path} || $args{name} ) ) {
        croak "Datastore $args{store} not known" unless $args{host}->datastore( $args{store} );
        $args{image}
            = $args{path}
            ? "[$args{store}] $args{path}"
            : "[$args{store}] $args{name}/$args{name}.vmx";
    } else {
        croak "Must specify either an 'image', a 'store' and 'path', or a 'store' and 'name'";
    }
    my ( $err, $vmHandle ) = VMOpen( ${ $args{host} }, $args{image} );
    croak "VMware::Vix::VM->new: " . GetErrorText($err) if $err != VIX_OK;
    return bless \$vmHandle, $class;
}

sub get_property {
    my $self = shift;
    my %args = @_;
    croak "No name provided" unless $args{name};
    croak "No lookup value for $args{name}"
        unless exists $PROPERTY{ $args{name} };
    my ( $err, $value ) = GetProperties( $$self, $PROPERTY{ $args{name} } );
    croak "VMware::Vix::VM->get_property: " . GetErrorText($err)
        if $err != VIX_OK;
    return $value;
}

sub ip {
    my $self = shift;
    my ( $err, $value ) = VMReadVariable( $$self, VIX_VM_GUEST_VARIABLE, "ip", 0);
    croak "VMware::Vix::VM->ip: " . GetErrorText($err)
        if $err != VIX_OK;
    return $value;
}

sub power_state {
    my $self = shift;
    my $num = $self->get_property( name => "power_state" );
    my @flags
        = map { $POWERSTATE{$_} } grep { $num & $_ } sort {$a <=> $b} keys %POWERSTATE;
    return dualvar( $num, join( ", ", @flags ) || "??" );
}

sub power_on {
    my $self = shift;
    my %args = @_;
    my $err  = VMPowerOn( $$self, VIX_VMPOWEROP_NORMAL, VIX_INVALID_HANDLE );
    croak "VMware::Vix::VM->power_on: " . GetErrorText($err)
        if $err != VIX_OK;
    return 1;
}

sub absolute {
    my $self = shift;
    my $path = shift;
    unless ($path =~m{\[}) {
        my $base = $self->path;
        $base =~ s{/[^/]+$}{/};
        $path = $base . $path;
    }
    $path =~ s{^\[(.*?)\] }{VMware::Vix::Host->datastore($1)."/"}e and defined VMware::Vix::Host->datastore($1)
        or return undef;
    return $path;
}

sub path {
    my $self = shift;
    return $self->get_property( name => "pathname" );
}

sub load_config {
    my $self = shift;
    return if $CONFIG{$self};
    $CONFIG{$self} = {};
    open(CONFIG, "<", $self->absolute( $self->path ) );
    while (<CONFIG>) {
        next unless /\S/;
        next if /^#/;
        $CONFIG{$self}{$1} = $2 if /\s*(\S+)\s*=\s*"(.*)"\s*$/;
    }
}

sub config {
    my $self = shift;
    my $key = shift;
    $self->load_config;
    return $CONFIG{$self}{$key};
}

sub disk {
    my $self = shift;
    return $self->config("scsi0:0.fileName");
}

sub defragment {
    my $self = shift;
    system("vmware-vdiskmanager","-d", $self->absolute( $self->disk ) );
}

sub mount {
    my $self = shift;
    my $path = shift;
    croak "Already mounted at $MOUNTS{$self}" if $MOUNTS{"$self"};
    !system( '/usr/bin/vmware-mount', $self->absolute( $self->disk ), $path )
        or croak "mount failed: $@";
    $MOUNTS{"$self"} = $path;
    return 1;
}

sub unmount {
    my $self = shift;
    return unless $MOUNTS{"$self"};
    !system( '/usr/bin/vmware-mount', '-d', delete $MOUNTS{"$self"} )
        or croak "unmount failed: $@";
    return 1;
}

sub snapshot {
    my $self = shift;
    my ( $err, $snapHandle ) = VMCreateSnapshot(
        $$self,
        undef,    # name
        undef,    #description
        VIX_SNAPSHOT_INCLUDE_MEMORY,
        VIX_INVALID_HANDLE
    );
    croak "VMware::Vix::VM->snapshot: " . GetErrorText($err)
        if $err != VIX_OK;
    return $snapHandle;
}

sub login {
    my $self = shift;
    my ($user, $password) = @_;
    my $err = VMLoginInGuest( $$self, $user, $password, 0);
    croak "VMware::Vix::VM->login: " . GetErrorText($err)
        if $err != VIX_OK;
    return 1;
}

sub copy {
    my $self = shift;
    my ($src, $dst) = @_;
    my $err = VMCopyFileFromGuestToHost($$self, $src, $dst, 0, VIX_INVALID_HANDLE);
    croak "VMware::Vix::VM->copy: " . GetErrorText($err)
        if $err != VIX_OK;
    return 1;
}

sub DESTROY {
    my $self = shift;
    $self->unmount;
    delete $CONFIG{$self};
    ReleaseHandle($$self);
}

1;

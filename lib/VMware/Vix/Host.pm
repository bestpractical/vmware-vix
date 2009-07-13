package VMware::Vix::Host;
use VMware::Vix::Simple;
use VMware::Vix::API::Constants;
use VMware::Vix::VM;
use Carp;

use Term::ReadKey qw//;

use XML::Simple;
our %DATASTORES;

BEGIN {
    my $stores
        = XMLin( "/etc/vmware/hostd/datastores.xml", ForceArray => ["e"] );
    if ($stores) {
        for my $k ( keys %{ $stores->{LocalDatastores}{e} } ) {
            $DATASTORES{$k} = $stores->{LocalDatastores}{e}{$k}{path};
        }
    }
}

sub new {
    my $class = shift;
    my %args  = (
        host => "https://localhost:8333/sdk",
        user => $ENV{USER},
        password => undef,
        @_,
    );
    unless (defined $args{password}) {
        print "Enter password for $args{user} to connect to VMware Server: ";
        Term::ReadKey::ReadMode('noecho');
        $args{password} = <STDIN>;
        Term::ReadKey::ReadMode('restore');
        chomp $args{password};
        print "\n";
    }
    
    my ( $err, $hostHandle ) = HostConnect( VIX_API_VERSION,
        VIX_SERVICEPROVIDER_VMWARE_VI_SERVER,
        $args{host},
        0,
        $args{user},
        $args{password},
        0,
        VIX_INVALID_HANDLE
    );
    croak "VMware::Vix::Host->new: " . GetErrorText($err) if $err != VIX_OK;
    return bless \$hostHandle, $class;
}

sub vms {
    my $self = shift;
    my ( $err, @vms ) = FindItems( $$self, VIX_FIND_REGISTERED_VMS, 0 );
    croak "VMware::Vix::Host->vms: " . GetErrorText($err) if $err != VIX_OK;
    return @vms;
}

sub open {
    my $self = shift;
    return VMware::Vix::VM->new( @_, host => $self );
}

sub disconnect {
    my $self = shift;
    HostDisconnect($$self);
}

sub datastore {
    my $class = shift;
    return keys %DATASTORES unless @_;
    my $name  = shift;
    return $DATASTORES{$name};
}

sub DESTROY {
    shift->disconnect;
}

1;

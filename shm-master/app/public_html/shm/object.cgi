#!/usr/bin/perl

use v5.14;

use SHM qw(:all);
my $user = SHM->new();

use Core::System::ServiceManager qw( get_service );
use Core::Utils qw(
    parse_args
    start_of_month
    http_limit
    http_content_range
    now
    switch_user
    decode_json
    html_escape
);

my %headers;
our %in = parse_args();
delete $in{where};

my $res;
my $admin = $user->authenticated->is_admin;

# Switch to user
if ( $admin && $in{user_id} ) {
    switch_user( $in{user_id} );
}

$in{object} ||= $ENV{PATH_INFO};

unless ( $in{object} ) {
    print_header( status => 400 );
    print_json( { error => html_escape("Unknown object") } );
    exit 0;
}

$in{object} =~s/.*\///;
$in{object} =~s/\.\w+$//;
# Convert to lamelcase
$in{object} = join('', map( ucfirst $_, split /_/, $in{object} ));

my $service_name = $in{object};

our $service = get_service( $service_name, ( $in{id} ? ( _id => $in{id} ) : () ) );
unless ( $service ) {
    print_header( status => 400 );
    print_json( { error => html_escape("`$service_name` not exists") } );
    exit 0;
}

unless ( $service->can('table') ) {
    print_header( status => 400 );
    print_json( { error => html_escape("service not supported API") } );
    exit 0;
}

if ( $ENV{REQUEST_METHOD} =~ /POST|PUT|DELETE/ ) {
    my $session = get_service('sessions')->validate(session_id => $in{session_id});
    unless ($session) {
        print_header( status => 401, location => '/shm/user/auth.cgi' );
        print_json( { error => html_escape('Session expired, please login again') } );
        exit 0;
    }
    unless ($session->validate_csrf_token($in{csrf_token})) {
        print_header( status => 403 );
        print_json( { error => html_escape('Invalid CSRF token') } );
        exit 0;
    }
}

if ( $in{method} ) {
    my $method = "api_$in{method}";
    if ( $service->can( $method ) ) {
        $res = $service->$method( %in, admin => $admin );
        if ( !ref $res ) {
            $res = [ $res ];
        }
    }
    else {
        %headers = ( status => 404 );
        $res = { error => html_escape("Method not found") };
    }
} elsif ( $ENV{REQUEST_METHOD} eq 'PUT' ) {
    if ( my $ret = $service->api( 'add', %in, admin => $admin ) ) {
        my %data = ref $ret ? $ret->get : $service->id( $ret )->get;
        $res = \%data;
    }
    else {
        %headers = ( status => 400 );
        $res = { error => html_escape("Can't add new object") };
    }
}
elsif ( $ENV{REQUEST_METHOD} eq 'POST' ) {
    if ( $service = $service->id( get_service_id() ) ) {
        $service->api( 'set', %in, admin => $admin );
        my %ret = $service->get;
        $res = \%ret;
    } else {
        %headers = ( status => 404 );
        $res = { error => html_escape("Object not found") };
    }
}
elsif ( $ENV{REQUEST_METHOD} eq 'DELETE' ) {
    if ( my $obj = $service->id( get_service_id() ) ) {
        $obj->api( 'delete', %in, admin => $admin );
        %headers = ( status => 204 );
    } else {
        %headers = ( status => 404 );
        $res = { error => html_escape("Service not found") };
    }
}
else {
    $in{filter} = decode_json( $in{filter} ) if $in{filter};

    my @ret = $service->list_for_api( %in, admin => $admin );
    $res = {
        items => $service->found_rows(),
        limit => $in{limit} || 25,
        offset => $in{offset} || 0,
        data => \@ret,
    };

    my $numRows = $service->found_rows;
    %headers = http_content_range( http_limit, count => $numRows );
}

my $report = get_service('report');

unless ( $report->is_success ) {
    %headers = ( status => 400 );
    $res = { error => html_escape($report->errors) };
}

print_header( %headers );
print_json( html_escape($res) );

$user->commit();

exit 0;

sub get_service_id {
    my $service_id = $in{ $service->get_table_key } || $in{id};

    unless ( $service_id ) {
        print_header( status => 400 );
        print_json( { error => html_escape('`id` not present') } );
        exit 0;
    }
    return $service_id;
}

package Core::Template;

use v5.14;
use utf8;
use parent 'Core::Base';
use Core::Base;
use Template;

use Core::Utils qw(
    encode_json_perl
    encode_json
    decode_json
    parse_args
    parse_headers
    blessed
    encode_base64url
    decode_base64url
    to_query_string
);

sub table { return 'templates' };

sub structure {
    return {
        id => {
            type => 'text',
            key => 1,
        },
        data => {
            type => 'text',
        },
        settings => { type => 'json', value => {} },
    }
}

sub parse {
    my $self = shift;
    my %args = (
        usi => undef,
        data => undef,
        task => undef,
        server_id => undef,
        event_name => undef,
        vars => {},
        START_TAG => '{{',
        END_TAG => '}}',
        get_smart_args( @_ ),
    );

    my $data = $args{data} || $self->data || return '';

    my (
        $pay_id,
        $bonus_id,
    );

    if ( $args{task} && blessed( $args{task} ) ) {
        $args{event_name} //= $args{task}->event->{name};
        $pay_id = $args{task}->get_settings->{pay_id};
        $bonus_id = $args{task}->get_settings->{bonus_id};
    }

    my $vars = {
        user => sub { get_service('user') },
        us => sub { get_service('us', _id => $args{usi}) },
        $args{task} ? ( task => $args{task} ) : (),
        server => sub { get_service('server', _id => $args{server_id}) },
        servers => sub { get_service('server') },
        sg => sub { get_service('ServerGroups') },
        pay => sub { get_service('pay', _id => $pay_id) },
        bonus => sub { get_service('bonus', _id => $bonus_id) },
        wd => sub { get_service('withdraw') },
        config => sub { get_service('config')->data_by_name },
        tpl => $self,
        service => sub { get_service('service') },
        services => sub { get_service('service') },
        storage => sub { get_service('storage') },
        telegram => sub { get_service('Transport::Telegram', task => $args{task}) },
        tg_api => sub { encode_json_perl( shift, pretty => 1 ) }, # for testing templates
        response => { test_data => 1 },  # for testing templates
        http => sub { get_service('Transport::Http') },
        spool => sub { get_service('Spool') },
        promo => sub { get_service('promo') },
        misc => sub { get_service('misc') },
        $args{event_name} ? ( event_name => uc $args{event_name} ) : (),
        %{ $args{vars} }, # do not move it upper. It allows to override promo end others
        request => sub {
            my %params = parse_args();
            my %headers = parse_headers();

            return {
                params => \%params,
                headers => \%headers,
            };
        },
        ref => sub {
            my $data = shift;
            return ref $data eq 'HASH' ? [ $data ] : ( $data || [] );
        },
        toJson => sub {
            my $data = shift;
            # for compatibility with other Cyrillic texts in the templates
            return encode_json_perl( $data );
        },
        fromJson => sub {
            my $data = shift;
            return decode_json( $data );
        },
        dump => sub {
            use Data::Dumper;
            return Dumper( @_ );
        },
        toQueryString => sub { to_query_string( shift ) },
        toBase64Url => sub { encode_base64url( shift ) },
        fromBase64Url => sub { decode_base64url( shift ) },
        true => \1,
        false => \0,
    };

    my $template = Template->new({
        START_TAG => quotemeta( $args{START_TAG} ),
        END_TAG   => quotemeta( $args{END_TAG} ),
        ANYCASE => 1,
        INTERPOLATE  => 0,
        PRE_CHOMP => 1,
        EVAL_PERL => 1,
    });

    my $result = "";
    unless ($template->process( \$data, $vars, \$result )) {
        my $report = get_service('report');
        $report->add_error( '' . $template->error() );
        logger->error("Template render error: ", $template->error() );
        return '';
    }

    $result =~s/^(\s+|\n|\r)+//;
    $result =~s/(\s+|\n|\r)+$//;

    return $result;
}

sub show {
    my $self = shift;
    my %args = (
        id => undef,
        do_not_parse => 0,
        @_,
    );

    my $template = $self->id( delete $args{id} );

    unless ( $template ) {
        logger->warning("Template not found");
        get_service('report')->add_error('Template not found');
        return undef;
    }

    if ( $args{do_not_parse} ) {
        return $template->get->{data};
    } else {
        return scalar $template->parse( %args );
    }
}

sub show_public {
    my $self = shift;
    my %args = (
        id => undef,
        @_,
    );

    my $template = $self->id( $args{id} );
    unless ( $template ) {
        logger->warning("Template not found");
        get_service('report')->add_error('Template not found');
        return undef;
    }

    unless ( $template->get_settings->{allow_public} ) {
        logger->warning("Template not public");
        get_service('report')->add_error('Permission denied: template is not public');
        return undef;
    }

    return $self->show( %args, do_not_parse => 0 );
}

sub _list {
    my $self = shift;
    my %args = (
        @_,
    );

    if ( my $id = $args{id} ) {
        $args{where}->{id} ||= $id;
    }
    return $self->SUPER::_list( %args );
}

sub add {
    my $self = shift;
    my %args = (
        @_,
    );

    return $self->SUPER::add(
        %args,
        data => $args{data} || delete $args{PUTDATA},
    );
}

sub set {
    my $self = shift;
    my %args = (
        @_,
    );

    return $self->SUPER::set(
        %args,
        data => $args{data} || delete $args{POSTDATA},
    );
}

1;

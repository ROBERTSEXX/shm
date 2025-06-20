package Core::Sessions;

use v5.14;
use parent 'Core::Base';
use Core::Base;
use Core::Utils qw( now );
use MIME::Base64 ();
use constant SESSION_TIMEOUT_MINUTES => 30;

sub table { return 'sessions' };

sub table_allow_insert_key { return 1 };

sub structure {
    return {
        id => {
            type => 'text',
            key => 1,
        },
        user_id => {
            type => 'number',
        },
        created => {
            type => 'text',
        },
        updated => {
            type => 'text',
        },
        settings => { type => 'json', value => {} },
    }
}

sub _generate_id {
    my @chars =('a' .. 'z', 0 .. 9, 'A' .. 'Z', 0 .. 9);
    my $session_id = join('', @chars[ map { rand @chars } (1 .. 32) ]);

    return $session_id;
}

sub add {
    my $self = shift;
    my %args = (
        id => _generate_id(),
        user_id => $self->SUPER::user_id,
        @_,
    );
    $args{id} = $self->encrypt_session_id($args{id});
    $args{settings} = $self->encrypt_settings($args{settings} || {});
    $args{created} = now();
    $args{updated} = now();
    my $session_id = $self->SUPER::add( %args );
    $self->_delete_expired;
    $self->res->{id} = $session_id;
    # Генерация CSRF-токена при создании сессии
    $self->generate_csrf_token;
    return $session_id;
}

sub validate {
    my $self = shift;
    my %args = (
        session_id => undef,
        @_,
    );

    my $session = $self->id( $args{session_id} );
    return undef unless $session;

    my $now = time();
    my $updated = string_to_utime($session->{updated});
    if ($now - $updated > SESSION_TIMEOUT_MINUTES * 60) {
        $self->delete($args{session_id});
        return undef;
    }

    $self->_set(
        updated => now,
        where => {
            id => $args{session_id},
        },
    );

    return $session;
}

sub _delete_expired {
    my $self = shift;

    $self->_delete(
        where => {
            updated => { '<', \[ 'NOW() - INTERVAL ? DAY', 3 ] },
        },
    );
}

sub delete {
    my $self = shift;

    $self->_delete_expired;
    $self->SUPER::delete( @_ );
}

sub delete_user_sessions {
    my $self = shift;
    my %args = (
        user_id => undef,
        @_,
    );

    return undef unless $args{user_id};

    return $self->_delete(
        where => {
            user_id => $args{user_id},
        },
    );
}

sub delete_all {
    my $self = shift;

    return $self->SUPER::_delete(
        where => {
            user_id => $self->SUPER::user_id,
        },
    );
}

sub user_id {
    my $self = shift;

    return $self->res->{user_id};
}

sub generate_csrf_token {
    my $self = shift;
    my $token = join '', map { ( 'a'..'z', 'A'..'Z', 0..9 )[rand 62] } 1..32;
    $self->set_csrf_token($token);
    return $token;
}

sub set_csrf_token {
    my ($self, $token) = @_;
    my $settings = $self->res->{settings} || {};
    $settings->{csrf_token} = $token;
    $self->set(settings => $settings);
}

sub get_csrf_token {
    my $self = shift;
    my $settings = $self->res->{settings} || {};
    return $settings->{csrf_token};
}

sub validate_csrf_token {
    my ($self, $token) = @_;
    return $token && $token eq $self->get_csrf_token;
}

sub encrypt_session_id {
    my ($self, $id) = @_;
    my $key = 'shm_secret_key';
    my $enc = join '', map { chr(ord($_) ^ ord(substr($key, $_ % length($key), 1))) } split //, $id;
    return MIME::Base64::encode_base64url($enc);
}

sub decrypt_session_id {
    my ($self, $enc) = @_;
    my $key = 'shm_secret_key';
    my $id = MIME::Base64::decode_base64url($enc);
    return join '', map { chr(ord($_) ^ ord(substr($key, $_ % length($key), 1))) } split //, $id;
}

sub encrypt_settings {
    my ($self, $settings) = @_;
    my $json = encode_json($settings);
    my $key = 'shm_secret_key';
    my $enc = join '', map { chr(ord($_) ^ ord(substr($key, $_ % length($key), 1))) } split //, $json;
    return MIME::Base64::encode_base64url($enc);
}

sub decrypt_settings {
    my ($self, $enc) = @_;
    my $key = 'shm_secret_key';
    my $json = MIME::Base64::decode_base64url($enc);
    $json = join '', map { chr(ord($_) ^ ord(substr($key, $_ % length($key), 1))) } split //, $json;
    return decode_json($json);
}

sub id {
    my $self = shift;
    my $enc_id = shift;
    my $id = $self->decrypt_session_id($enc_id);
    my $session = $self->SUPER::id($id);
    if ($session && $session->{settings}) {
        $session->{settings} = $self->decrypt_settings($session->{settings});
    }
    $self->res($session) if $session;
    return $self;
}

1;

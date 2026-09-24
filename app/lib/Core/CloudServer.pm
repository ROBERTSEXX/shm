package Core::CloudServer;

# Серверная часть SHM Cloud: то, что клиентские установки SHM получают
# через Core::Cloud (подписка, платежные системы, курсы валют).
# Маршруты /cloud/* включаются переменной окружения SHM_CLOUD_SERVER=1,
# клиенты подключаются через SHM_CLOUD_URL=https://<host>/shm/v1/cloud

use v5.14;
use utf8;
use parent 'Core::Base';
use Core::Base;
use Core::Const;
use Core::Utils qw(
    now
    get_user_ip
    decode_json
    switch_user
);

use constant {
    CURRENCIES_URL       => 'https://www.cbr.ru/scripts/XML_daily.asp',
    CURRENCIES_CACHE_KEY => 'cloud_server_currencies',
    CURRENCIES_TTL       => 3600,
    CURRENCIES_RETRY     => 300,
    CLIENT_SEEN_INTERVAL => 3600,
};

my %ADDITION_TYPES = map { $_ => 1 } qw( fixed numeric percent );

sub server_config {
    my $self = shift;

    return {
        strict_ip    => 1,
        sub_category => 'cloud-sub',
        ps_category  => 'cloud-ps',
        tg_url       => undef,
        currencies   => {},
        %{ scalar cfg('cloud_server') },
    };
}

# Аккаунт облака привязывается к IP сервера клиента при регистрации или первом входе.
# Сменить привязку можно через auth_reset, зная логин и пароль.
sub _check_client {
    my $self = shift;
    my $user = shift;

    my $cloud = ( $user->get_settings || {} )->{cloud} || {};
    my $ip = get_user_ip();
    my %update;

    if ( $self->server_config->{strict_ip} ) {
        if ( !$cloud->{ip} ) {
            $update{ip} = $ip;
        } elsif ( $cloud->{ip} ne $ip ) {
            report->status( 403 );
            report->add_error('Login from this IP is prohibited');
            return 0;
        }
    }

    my $version = $ENV{HTTP_SHM_INFO_VER};
    my $client = $cloud->{client} || {};
    if ( ( $version && ( $client->{version} // '' ) ne $version ) ||
         time - ( $client->{seen} || 0 ) > CLIENT_SEEN_INTERVAL ) {
        $update{client} = {
            $version ? ( version => $version ) : (),
            seen => time,
        };
    }

    $user->set_settings({ cloud => \%update }) if %update;
    return 1;
}

sub _auth_user {
    my $self = shift;
    my %args = @_;

    my $user = get_service('user')->auth(
        login    => $args{login},
        password => $args{password},
    );

    unless ( $user ) {
        report->status( 401 );
        report->add_error('Incorrect login or password') if report->is_success;
        return undef;
    }

    return $user;
}

sub auth {
    my $self = shift;
    my %args = (
        login    => undef,
        password => undef,
        @_,
    );

    my $user = $self->_auth_user( %args );
    unless ( $user ) {
        $self->set_user_fail_attempt( 'auth', 180 );
        return undef;
    }

    switch_user( $user->id );
    return undef unless $self->_check_client( $user );

    $user->set( last_login => now );

    return {
        user_id => $user->id,
        login   => $user->get_login,
    };
}

sub auth_reset {
    my $self = shift;
    my %args = (
        login    => undef,
        password => undef,
        @_,
    );

    my $user = $self->_auth_user( %args );
    unless ( $user ) {
        $self->set_user_fail_attempt( 'auth_reset', 3600 );
        return undef;
    }

    switch_user( $user->id );
    $user->set_settings({ cloud => { ip => get_user_ip() } });

    return {
        user_id => $user->id,
        ip      => get_user_ip(),
    };
}

sub reg {
    my $self = shift;
    my %args = (
        login          => undef,
        password       => undef,
        captcha_token  => undef,
        captcha_answer => undef,
        @_,
    );

    $self->set_user_fail_attempt( 'reg', 3600 );

    # Капчу проверяем всегда, независимо от billing.allow_user_register_captcha
    unless ( get_service('user')->verify_captcha(
        token  => $args{captcha_token},
        answer => $args{captcha_answer},
    ) ) {
        report->status( 403 );
        report->add_error('Invalid captcha');
        return undef;
    }

    my $user = get_service('user')->reg_api_safe(
        login          => $args{login},
        password       => $args{password},
        captcha_token  => $args{captcha_token},
        captcha_answer => $args{captcha_answer},
    ) || return undef;

    $user->set_settings({ cloud => { ip => get_user_ip() } }) if $self->server_config->{strict_ip};

    return {
        user_id => $user->id,
        login   => $args{login},
    };
}

sub _services_by_category {
    my $self = shift;
    my $category = shift;

    return $self->srv('service')->_list(
        where => {
            category => $category,
            deleted  => 0,
        },
        order => [ cost => 'ASC', service_id => 'ASC' ],
    );
}

# Строки из join содержат поля обеих таблиц (например `next`), поэтому
# однозначны в них только поля user_services без пересечений: id, service_id, status
sub _user_services_by_category {
    my $self = shift;
    my $category = shift;

    return $self->srv('us')->_list(
        where => {
            category => $category,
            parent   => undef,
        },
        join    => { table => 'services', using => ['service_id'] },
        user_id => $self->user_id,
        order   => [ user_service_id => 'DESC' ],
    );
}

sub _subscription {
    my $self = shift;

    my ( $row ) = $self->_user_services_by_category( $self->server_config->{sub_category} );
    return $row ? $self->srv('us')->id( $row->{user_service_id} ) : undef;
}

sub _subscription_info {
    my $self = shift;
    my $us = shift;

    my $status = $us->get_status;
    my $next = $us->get_next;
    my $tg_url = $self->server_config->{tg_url};

    return {
        user_service_id => $us->id,
        service_id      => $us->get_service_id,
        name            => $us->name,
        status          => $status,
        expire          => $us->get_expire,
        # `next` пустой - продление той же услугой
        next            => $next ? $next : $us->get_service_id,
        ( $tg_url && $status eq STATUS_ACTIVE ) ? ( tg_url => $tg_url ) : (),
    };
}

sub sub_get {
    my $self = shift;

    return undef unless $self->_check_client( $self->user );

    my $us = $self->_subscription;
    unless ( $us ) {
        report->status( 404 );
        report->add_error('Subscription not found');
        return undef;
    }

    return $self->_subscription_info( $us );
}

sub sub_list {
    my $self = shift;

    return undef unless $self->_check_client( $self->user );

    my @services = $self->_services_by_category( $self->server_config->{sub_category} );
    my %by_id = map { $_->{service_id} => $_ } @services;

    my @list;
    for ( grep { $_->{allow_to_order} } @services ) {
        my $next = $_->{next} && $_->{next} > 0 ? $_->{next} : undef;
        my $next_service = $next ? $by_id{ $next } : undef;

        push @list, {
            service_id => $_->{service_id} + 0,
            name       => $_->{name},
            descr      => $_->{descr},
            period     => $_->{period} + 0,
            price      => $_->{cost} + 0,
            next       => $next_service ? $next + 0 : undef,
            price_next => $next_service ? $next_service->{cost} + 0 : undef,
        };
    }

    return \@list;
}

sub _sub_service {
    my $self = shift;
    my $service_id = shift;

    my ( $service ) = grep { $_->{service_id} == $service_id }
        $self->_services_by_category( $self->server_config->{sub_category} );

    unless ( $service ) {
        report->status( 404 );
        report->add_error('Subscription plan not found');
        return undef;
    }

    return $service;
}

# Заказ услуги: при нехватке средств заказ откатываем, чтобы не оставлять неоплаченных услуг
sub _order_service {
    my $self = shift;
    my $service_id = shift;

    my $us = $self->srv('us')->create(
        service_id           => $service_id,
        check_allow_to_order => 1,
    ) || return undef;

    if ( $us->get_status eq STATUS_WAIT_FOR_PAY ) {
        $self->rollback;
        report->status( 402 );
        report->add_error('insufficient money');
        return undef;
    }

    return $us;
}

sub sub_reg {
    my $self = shift;
    my %args = (
        service_id => undef,
        @_,
    );

    return undef unless $self->_check_client( $self->user );
    return undef unless $self->_sub_service( $args{service_id} );

    if ( $self->_subscription ) {
        report->status( 409 );
        report->add_error('Subscription already exists');
        return undef;
    }

    $self->set_user_fail_attempt( 'sub_reg', 600 );

    my $us = $self->_order_service( $args{service_id} ) || return undef;
    return $self->_subscription_info( $us );
}

sub sub_renewal {
    my $self = shift;
    my %args = (
        service_id => undef,
        @_,
    );

    return undef unless $self->_check_client( $self->user );

    my $us = $self->_subscription;
    unless ( $us ) {
        report->status( 404 );
        report->add_error('Subscription not found');
        return undef;
    }

    my $next = $args{service_id};
    if ( $next != -1 ) {
        my $service = $self->_sub_service( $next ) || return undef;
        unless ( $service->{cost} > 0 ) {
            report->status( 403 );
            report->add_error('The next service must not be free');
            return undef;
        }
        $next = undef if $next == $us->get_service_id;
    }

    $us->set( next => $next );

    return $self->_subscription_info( $us );
}

sub _ps_dirs {
    return (
        "$ENV{SHM_ROOT_DIR}/data/cloud/paysystems",
        "$ENV{SHM_ROOT_DIR}/cloud/paysystems",
    );
}

# Каталог платежных систем: <name>.json (описание и схема настроек) и <name>.cgi (модуль).
# Файлы из data/cloud/paysystems переопределяют встроенные из cloud/paysystems.
sub _ps_catalog {
    my $self = shift;

    my %catalog;
    for my $dir ( reverse $self->_ps_dirs ) {
        opendir( my $dh, $dir ) or next;
        for my $file ( sort readdir $dh ) {
            my ( $name ) = $file =~ /^([a-z0-9_]+)\.json$/ or next;
            next unless -f "$dir/$name.cgi";

            open my $fh, '<:raw', "$dir/$file" or next;
            my $meta = decode_json( do { local $/; <$fh> } );
            close $fh;

            unless ( ref $meta eq 'HASH' ) {
                logger->error("Incorrect pay system description: $dir/$file");
                next;
            }

            $catalog{ $name } = {
                %{ $meta },
                name => $name,
                file => "$dir/$name.cgi",
            };
        }
        closedir $dh;
    }

    return \%catalog;
}

# Платные модули - услуги категории ps_category с config.paysystem = <name>,
# модуль считается купленным при активной услуге пользователя
sub _ps_state {
    my $self = shift;
    my $category = $self->server_config->{ps_category};

    my %services;
    for ( $self->_services_by_category( $category ) ) {
        my $ps = ref $_->{config} eq 'HASH' ? $_->{config}->{paysystem} : undef;
        $services{ $ps } //= $_ if $ps;
    }

    my %status;
    for ( $self->_user_services_by_category( $category ) ) {
        $status{ $_->{service_id} }{ $_->{status} } = 1;
    }

    return {
        services => \%services,
        status   => \%status,
    };
}

sub _ps_info {
    my $self = shift;
    my $name = shift;
    my $state = shift || $self->_ps_state;

    my $service = $state->{services}->{ $name };
    return { price => 0, paid => 0 } unless $service;

    my $status = $state->{status}->{ $service->{service_id} } || {};

    return {
        service_id => $service->{service_id},
        price      => $service->{cost} + 0,
        paid       => $status->{ +STATUS_ACTIVE } ? 1 : 0,
        progress   => $status->{ +STATUS_PROGRESS } ? 1 : 0,
    };
}

sub ps_list {
    my $self = shift;

    return undef unless $self->_check_client( $self->user );

    my $catalog = $self->_ps_catalog;
    my $state = $self->_ps_state;

    my @list;
    for my $name ( sort keys %{ $catalog } ) {
        my $ps = $catalog->{ $name };
        my $info = $self->_ps_info( $name, $state );

        push @list, {
            name        => $name,
            title       => $ps->{title} // $name,
            description => $ps->{description} // '',
            version     => $ps->{version},
            fields      => $ps->{fields} || [],
            $ps->{infoMessage} ? ( infoMessage => $ps->{infoMessage} ) : (),
            price       => $info->{price},
            paid        => $info->{paid},
        };
    }

    return \@list;
}

sub _ps_get {
    my $self = shift;
    my $name = shift // '';

    my $ps = $self->_ps_catalog->{ $name };
    unless ( $ps ) {
        report->status( 404 );
        report->add_error('Pay system not found');
        return undef;
    }

    return $ps;
}

sub ps_order {
    my $self = shift;
    my %args = (
        ps => undef,
        @_,
    );

    return undef unless $self->_check_client( $self->user );

    my $ps = $self->_ps_get( $args{ps} ) || return undef;
    my $info = $self->_ps_info( $ps->{name} );

    if ( $info->{price} > 0 && !$info->{paid} && !$info->{progress} ) {
        $self->set_user_fail_attempt( 'ps_order', 600 );
        $self->_order_service( $info->{service_id} ) || return undef;
    }

    return {
        name => $ps->{name},
        paid => 1,
    };
}

sub ps_download {
    my $self = shift;
    my %args = (
        ps => undef,
        @_,
    );

    return undef unless $self->_check_client( $self->user );

    my $ps = $self->_ps_get( $args{ps} ) || return undef;
    my $info = $self->_ps_info( $ps->{name} );

    if ( $info->{price} > 0 && !$info->{paid} ) {
        report->status( 403 );
        report->add_error('Pay system is not paid');
        return undef;
    }

    open my $fh, '<:raw', $ps->{file} or do {
        logger->error("Can't read pay system file $ps->{file}: $!");
        report->status( 500 );
        report->add_error("Can't read pay system file");
        return undef;
    };
    my $content = do { local $/; <$fh> };
    close $fh;

    # Ответ API всегда кодируется в UTF-8, поэтому поддерживаются только текстовые модули
    unless ( utf8::decode( $content ) ) {
        report->status( 415 );
        report->add_error('Pay system module must be a UTF-8 text file');
        return undef;
    }

    return $content;
}

sub _fetch_currencies {
    my $self = shift;
    my $url = shift;

    my $response = $self->srv('Transport::Http')->http(
        url     => $url,
        method  => 'get',
        content => {},
        timeout => 10,
    );

    unless ( $response && $response->is_success ) {
        logger->warning("Can't load currencies from $url: " . ( $response ? $response->status_line : 'no response' ) );
        return undef;
    }

    my $xml = $response->decoded_content;
    my $updated = now();
    $updated =~ s/ /T/;

    my %list;
    while ( $xml =~ m{<Valute\b[^>]*>(.*?)</Valute>}sg ) {
        my $item = $1;
        my %f = map { $_ => ( $item =~ m{<$_>\s*([^<]*?)\s*</$_>} )[0] } qw( CharCode Nominal Name Value );
        next unless $f{CharCode} && $f{Nominal} && $f{Value};
        $f{Value} =~ tr/,/./;

        $list{ $f{CharCode} } = {
            currency => $f{CharCode},
            name     => $f{Name},
            nominal  => $f{Nominal} + 0,
            value    => 0 + sprintf( '%.6f', $f{Value} / $f{Nominal} ),
            updated  => $updated,
        };
    }

    unless ( %list ) {
        logger->warning("No currencies found in response from $url");
        return undef;
    }

    return \%list;
}

# Базовые курсы кешируются на час; если источник недоступен - отдаем
# последние известные курсы и повторяем попытку через CURRENCIES_RETRY
sub _base_currencies {
    my $self = shift;

    my $cfg = $self->server_config->{currencies} || {};
    my $cache = $self->cache;
    my $cached = $cache ? $cache->get_json( CURRENCIES_CACHE_KEY ) : undef;

    unless ( $cached && time - ( $cached->{checked} || 0 ) < CURRENCIES_TTL ) {
        if ( my $list = $self->_fetch_currencies( $cfg->{url} || CURRENCIES_URL ) ) {
            $cached = { list => $list, checked => time };
        } elsif ( $cached ) {
            $cached->{checked} = time - CURRENCIES_TTL + CURRENCIES_RETRY;
        } else {
            return undef;
        }
        $cache->set_json( CURRENCIES_CACHE_KEY, $cached, 0 ) if $cache;
    }

    my %list = %{ $cached->{list} };

    my $extra = $cfg->{extra} // {
        XTR => { name => 'Telegram Stars', base => 'USD', ratio => 0.013 },
    };
    for my $code ( keys %{ $extra } ) {
        my $e = $extra->{ $code };
        my $base = $e->{base} ? $list{ $e->{base} } : undef;
        my $value = $e->{value} // ( $base ? $base->{value} * ( $e->{ratio} // 1 ) : undef );
        next unless $value;

        $list{ $code } = {
            currency => $code,
            name     => $e->{name} // $code,
            nominal  => 1,
            value    => 0 + sprintf( '%.6f', $value ),
            updated  => $base ? $base->{updated} : $cached->{list}->{USD}->{updated},
        };
    }

    return \%list;
}

sub currencies {
    my $self = shift;

    return undef unless $self->_check_client( $self->user );

    my $list = $self->_base_currencies;
    unless ( $list ) {
        report->status( 503 );
        report->add_error('Currencies are temporarily unavailable');
        return undef;
    }

    my $modifiers = ( $self->user->get_settings || {} )->{cloud}->{currencies} || {};

    my %ret;
    for my $code ( keys %{ $list } ) {
        my $mod = $modifiers->{ $code };
        $ret{ $code } = {
            %{ $list->{ $code } },
            $mod ? (
                addition_type  => $mod->{addition_type},
                addition_value => $mod->{addition_value},
            ) : (),
        };
    }

    return \%ret;
}

sub currencies_save {
    my $self = shift;
    my %args = (
        currencies => {},
        @_,
    );

    return undef unless $self->_check_client( $self->user );

    my $list = $self->_base_currencies || {};
    my $settings = $self->user->get_settings || {};
    my %modifiers = %{ $settings->{cloud}->{currencies} || {} };

    for my $code ( keys %{ $args{currencies} || {} } ) {
        my $item = $args{currencies}->{ $code };
        my $type = ref $item eq 'HASH' ? $item->{addition_type} // '' : '';
        my $value = ref $item eq 'HASH' ? $item->{addition_value} // 0 : 0;

        unless ( $list->{ $code } ) {
            report->status( 400 );
            report->add_error("Unknown currency: $code");
            return undef;
        }

        if ( $type eq '' ) {
            delete $modifiers{ $code };
            next;
        }

        unless ( $ADDITION_TYPES{ $type } && $value =~ /^-?(?:\d+\.?\d*|\.\d+)$/ ) {
            report->status( 400 );
            report->add_error("Incorrect modifier for currency: $code");
            return undef;
        }

        if ( $type eq 'fixed' && $value <= 0 ) {
            report->status( 400 );
            report->add_error("Fixed rate must be positive: $code");
            return undef;
        }

        $modifiers{ $code } = {
            addition_type  => $type,
            addition_value => $value + 0,
        };
    }

    $settings->{cloud}->{currencies} = \%modifiers;
    $self->user->set( settings => $settings );

    return $self->currencies;
}

1;

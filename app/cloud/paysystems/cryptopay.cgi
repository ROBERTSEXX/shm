#!/usr/bin/perl

# Crypto Pay (@CryptoBot)
# https://help.crypt.bot/crypto-pay-api#createInvoice
# https://help.crypt.bot/crypto-pay-api#webhooks

use v5.14;
use LWP::UserAgent ();
use Digest::SHA qw( sha256 hmac_sha256_hex );
use Core::Utils qw(
    encode_utf8
    decode_json
);
use CGI ();

use SHM qw(:all);

my $PS = 'cryptopay';

our %vars = parse_args();

my $user = SHM->new( skip_check_auth => 1 );

# Копии платежной системы (ключи вида cryptopay_1) дополняют настройки основной
sub ps_config {
    my $key = shift || $PS;

    my $config = get_service('config', _id => 'pay_systems');
    my $data = $config ? $config->get_data : {};

    $key = $PS unless ref $data->{ $key } eq 'HASH' &&
        ( $key eq $PS || ( $data->{ $key }->{paysystem} // '' ) eq $PS );

    return ( $key, { %{ $data->{ $PS } || {} }, %{ $data->{ $key } || {} } } );
}

my ( $ps_name, $cfg ) = ps_config( $vars{ps} );

unless ( $cfg->{api_key} ) {
    print_json({ status => 400, msg => "Error: api_key required. Please set it in config pay_systems->$ps_name" });
    exit 0;
}

if ( $vars{action} eq 'create' ) {
    $user = $vars{user_id} ? SHM->new( user_id => $vars{user_id} ) : SHM->new();

    if ( $vars{message_id} ) {
        get_service('Transport::Telegram')->deleteMessage( message_id => $vars{message_id} );
    }

    my $description = $cfg->{description} || $vars{description} || 'Пополнение баланса';

    my $browser = LWP::UserAgent->new( timeout => 10 );
    $browser->default_header( 'Crypto-Pay-API-Token' => $cfg->{api_key}, 'User-Agent' => 'SHM' );

    my $response = $browser->post( 'https://pay.crypt.bot/api/createInvoice',
        Content => encode_utf8({
            currency_type  => 'fiat',
            fiat           => $cfg->{fiat} || 'RUB',
            amount         => $vars{amount} || 100,
            description    => sprintf( '%s [%d]', $description, $user->id ),
            payload        => $user->id,
            allow_comments => 'false',
            $cfg->{paid_btn_name} && $cfg->{paid_btn_url} ? (
                paid_btn_name => $cfg->{paid_btn_name},
                paid_btn_url  => $cfg->{paid_btn_url},
            ) : (),
        }),
    );

    my $data = $response->is_success ? decode_json( $response->decoded_content ) : undef;

    if ( $data && $data->{ok} ) {
        print_header(
            location => $data->{result}->{bot_invoice_url},
            status => 301,
        );
    } else {
        print_json({
            status => 503,
            decoded_content => $response->decoded_content,
            status_line => $response->status_line,
        });
    }

    exit 0;
}

# Подпись: HMAC-SHA256 тела запроса ключом SHA256(api_key)
my $body = CGI->new->param('POSTDATA') // '';
my $signature = lc( $ENV{HTTP_CRYPTO_PAY_API_SIGNATURE} // '' );

if ( $signature ne hmac_sha256_hex( $body, sha256( $cfg->{api_key} ) ) ) {
    print_json({ status => 400, msg => "Error: Signature doesn't match" });
    exit 0;
}

my $invoice = $vars{payload};
unless ( ref $invoice eq 'HASH' ) {
    print_json({ status => 400, msg => 'Error: bad request' });
    exit 0;
}

if ( ( $vars{update_type} // '' ) ne 'invoice_paid' || ( $invoice->{status} // '' ) ne 'paid' ) {
    print_json({ status => 200, msg => 'unknown event', event => $vars{update_type} });
    exit 0;
}

my $user_id = $invoice->{payload};
( $user_id ) = ( $invoice->{description} // '' ) =~ /\[(\d+)\]\s*$/ unless $user_id;

unless ( $user_id && ( $user = $user->id( $user_id ) ) ) {
    print_json({ status => 404, msg => 'User not found' });
    exit 0;
}

unless ( $user->lock( timeout => 10 ) ) {
    print_json({ status => 408, msg => 'The service is locked. Try again later' });
    exit 0;
}

$user->payment(
    user_id => $user_id,
    money => $invoice->{amount},
    pay_system_id => $ps_name,
    comment => \%vars,
    uniq_key => "invoice-$invoice->{invoice_id}",
);

$user->commit;

print_json({ status => 200, msg => 'payment successful' });

exit 0;

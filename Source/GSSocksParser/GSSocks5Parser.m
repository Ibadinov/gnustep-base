#import "GSSocks5Parser.h"
#import "GSSocksParserPrivate.h"
#import <arpa/inet.h>

typedef enum GSSocks5ParserState {
    GSSocks5ParserStateHandshake,
    GSSocks5ParserStateAuthenticationRequest,
    GSSocks5ParserStateAuthenticationResponse,
    GSSocks5ParserStateRequest,
    GSSocks5ParserStateResponse,
    GSSocks5ParserStateResponseAddressLength,
    GSSocks5ParserStateResponseAddressAndPort,
} GSSocks5ParserState;

typedef enum GSSocks5AuthenticationMethod {
    GSSocks5AuthenticationMethodNone                = 0x00,
    GSSocks5AuthenticationMethodGSSAPI              = 0x01,
    GSSocks5AuthenticationMethodPassword            = 0x02,
    GSSocks5AuthenticationMethodNoAcceptable        = 0xFF,
} GSSocks5AuthenticationMethod;

typedef enum GSSocks5ResponseStatus {
    GSSocks5ResponseStatusSuccess                   = 0x0,
    GSSocks5ResponseStatusGeneralFailure            = 0x1,
    GSSocks5ResponseStatusConnectionNotAllowed      = 0x2,
    GSSocks5ResponseStatusNetworkUnreachable        = 0x3,
    GSSocks5ResponseStatusHostUnreachable           = 0x4,
    GSSocks5ResponseStatusConnectionRefused         = 0x5,
    GSSocks5ResponseStatusTTLExpired                = 0x6,
    GSSocks5ResponseStatusCommandNotSupported       = 0x7,
    GSSocks5ResponseStatusAddressTypeNotSupported   = 0x8,
} GSSocks5ResponseStatus;

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wcast-align"

@implementation GSSocks5Parser

- (id)initWithConfiguration:(NSDictionary *)aConfiguration
                    address:(NSString *)anAddress
                       port:(NSUInteger)aPort
{
    if (self = [super init]) {
        configuration = [aConfiguration retain];
        address = [anAddress retain];
        port = aPort;
        stopped = YES;
    }
    return self;
}

- (void)start
{
    state = GSSocks5ParserStateHandshake;
    stopped = NO;
    
    uint8_t bytes[3] = {0x5, 0x1, GSSocks5AuthenticationMethodNone};
    if ([configuration objectForKey:NSStreamSOCKSProxyUserKey]) {
        bytes[2] = GSSocks5AuthenticationMethodPassword;
    }
    
    [delegate parser:self formedRequest:[NSData dataWithBytes:bytes length:3]];
    [delegate parser:self needsMoreBytes:2];
}

- (NSError *)errorWithResponseStatus:(NSInteger)aStatus
{
    NSString *description;
    switch ((GSSocks5ResponseStatus)aStatus) {
        case GSSocks5ResponseStatusGeneralFailure:
            description = @"general server failure";
            break;
        case GSSocks5ResponseStatusConnectionNotAllowed:
            description = @"connection is not allowed by a ruleset";
            break;
        case GSSocks5ResponseStatusNetworkUnreachable:
            description = @"destination network is unreachable";
            break;
        case GSSocks5ResponseStatusHostUnreachable:
            description = @"destination host is unreachable";
            break;
        case GSSocks5ResponseStatusConnectionRefused:
            description = @"connection has been refused";
            break;
        case GSSocks5ResponseStatusTTLExpired:
            description = @"connection has timed out";
            break;
        case GSSocks5ResponseStatusCommandNotSupported:
            description = @"command is not supported";
            break;
        case GSSocks5ResponseStatusAddressTypeNotSupported:
            description = @"address type is not supported";
            break;
        default:
            description = @"unkown";
            break;
    }
    description = [NSString stringWithFormat:@"SOCKS5 server failed to fulfil request, reason: %@", description];
    return [self errorWithCode:aStatus description:description];
}

- (void)reportError:(NSError *)anError
{
    stopped = YES;
    [delegate parser:self encounteredError:anError];
}

- (void)parseNextChunk:(NSData *)aChunk
{
    if (stopped) {
        return;
    }
    const uint8_t *bytes = [aChunk bytes];
    switch ((GSSocks5ParserState)state) {
        case GSSocks5ParserStateHandshake:
        {
            if (bytes[1] == GSSocks5AuthenticationMethodNoAcceptable) {
                NSError *error = [self errorWithCode:GSSocks5AuthenticationMethodNoAcceptable
                                         description:@"SOCKS server does not support requested authentication method"];
                [self reportError:error];
                break;
            }
            if (![configuration objectForKey:NSStreamSOCKSProxyUserKey]) {
                state = GSSocks5ParserStateRequest;
                goto GSSocks5ParserStateRequest;
            }
            state = GSSocks5ParserStateAuthenticationRequest;
        }
        case GSSocks5ParserStateAuthenticationRequest:
        {
            NSString *username = [configuration objectForKey:NSStreamSOCKSProxyUserKey];
            NSString *password = [configuration objectForKey:NSStreamSOCKSProxyPasswordKey];
            uint8_t bytes[3] = {0x5, (uint8_t)[username length], (uint8_t)[password length]};
            NSMutableData *request = [NSMutableData dataWithCapacity:bytes[1] + bytes[2] + 3];
            [request appendBytes:bytes length:2];
            [request appendBytes:[username UTF8String] length:bytes[1]];
            [request appendBytes:&bytes[2] length:1];
            [request appendBytes:[password UTF8String] length:bytes[2]];
            
            state = GSSocks5ParserStateAuthenticationResponse;
            [delegate parser:self formedRequest:request];
            [delegate parser:self needsMoreBytes:2];
            break;
        }
        case GSSocks5ParserStateAuthenticationResponse:
        {
            if (bytes[1]) {
                NSError *error = [self errorWithCode:0xFF + bytes[1]
                                         description:@"SOCKS authentication failed"];
                [self reportError:error];
                break;
            }
            state = GSSocks5ParserStateRequest;
        }
        GSSocks5ParserStateRequest:
        case GSSocks5ParserStateRequest:
        {
            GSSocksAddressType type = [self addressType];
            uint8_t request[4] = {
                0x5, 0x1, 0x0, type
            };
            NSMutableData *data = [NSMutableData dataWithBytes:request length:4];
            NSData *addressData = [self addressData];
            if (type == GSSocksAddressTypeDomain) {
                uint8_t length = (uint8_t)[addressData length];
                [data appendBytes:&length length:1];
            }
            [data appendData:addressData];
            uint16_t portWithNetworkEndianness = htons((uint16_t)port);
            [data appendBytes:&portWithNetworkEndianness length:2];
            
            state = GSSocks5ParserStateResponse;
            [delegate parser:self formedRequest:data];
            [delegate parser:self needsMoreBytes:4];
            break;
        }
        case GSSocks5ParserStateResponse:
        {
            if (bytes[1] != GSSocks5ResponseStatusSuccess) {
                NSError *error = [self errorWithResponseStatus:bytes[1]];
                [self reportError:error];
                break;
            }
            addressType = bytes[3]; /* addess type */
            if (addressType == GSSocksAddressTypeDomain) {
                state = GSSocks5ParserStateResponseAddressLength;
                [delegate parser:self needsMoreBytes:1];
            } else {
                state = GSSocks5ParserStateResponseAddressAndPort;
                addressSize = addressType == GSSocksAddressTypeIPv4 ? 4 : 16;
                [delegate parser:self needsMoreBytes:addressSize + 2];
            }
            break;
        }
        case GSSocks5ParserStateResponseAddressLength:
        {
            addressSize = bytes[0];
            state = GSSocks5ParserStateResponseAddressAndPort;
            [delegate parser:self needsMoreBytes:addressSize + 2];
            break;
        }
        case GSSocks5ParserStateResponseAddressAndPort:
        {
            NSString    *bndAddress = [self addressFromData:[NSData dataWithBytes:[aChunk bytes] length:addressSize]
                                                   withType:addressType];
            NSUInteger  bndPort     = ntohs(*(uint16_t *)(bytes + addressSize));
            [delegate parser:self finishedWithAddress:bndAddress port:bndPort];
            break;
        }
    }
}

@end

#pragma GCC diagnostic pop
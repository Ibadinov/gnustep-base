#import "GSSocks4Parser.h"
#import "GSSocksParserPrivate.h"

typedef enum GSSocks4InternalError {
    GSSocks4InternalErrorIPv6 = 0x4a
} GSSocks4InternalError;

typedef enum GSSocks4ResponseStatus {
    GSSocks4ResponseStatusAccessGranted     = 0x5a,
    GSSocks4ResponseStatusRequestRejected   = 0x5b,
    GSSocks4ResponseStatusIdentdFailed      = 0x5c,
    GSSocks4ResponseStatusUserNotConfirmed  = 0x5d,
} GSSocks4ResponseStatus;

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wcast-align"

@implementation GSSocks4Parser

- (id)initWithConfiguration:(NSDictionary *)aConfiguration
                    address:(NSString *)anAddress
                       port:(NSUInteger)aPort
{
    if (self = [super init]) {
        configuration = [aConfiguration retain];
        address = [anAddress retain];
        port = aPort;
    }
    return self;
}

+ (void)load
{
    [self registerSubclass:self forProtocolVersion:NSStreamSOCKSProxyVersion4];
}

- (void)start
{
    GSSocksAddressType addressType = [self addressType];
    if (addressType == GSSocksAddressTypeIPv6) {
        NSError *error = [self errorWithCode:GSSocks4InternalErrorIPv6
                                 description:@"IPv6 addresses are not supported by SOCKS4 porxies"];
        [delegate parser:self encounteredError:error];
        return;
    }
    
    NSMutableData *data = [NSMutableData dataWithLength:8];
    uint8_t *bytes = [data mutableBytes];
    bytes[0] = 0x4;
    bytes[1] = 0x1;
    *(uint16_t *)(bytes + 2) = htons((uint16_t)port);
    if (addressType == GSSocksAddressTypeDomain) {
        bytes[4] = bytes[5] = bytes[6] = 0;
        bytes[7] = 1;
    } else {
        const uint32_t *addressBytes = [[self addressData] bytes];
        *(uint32_t *)(bytes + 4) = htonl(*addressBytes);
    }
    uint8_t zero = 0x0;
    NSString *user = [configuration objectForKey:NSStreamSOCKSProxyUserKey];
    if (user) {
        [data appendData:[user dataUsingEncoding:NSUTF8StringEncoding]];
        [data appendBytes:&zero length:1];
    }
    if (addressType == GSSocksAddressTypeDomain) {
        [data appendData:[address dataUsingEncoding:NSUTF8StringEncoding]];
        [data appendBytes:&zero length:1];
    }
    
    [delegate parser:self formedRequest:data];
    [delegate parser:self needsMoreBytes:8];
}

- (NSError *)errorWithResponseStatus:(NSInteger)aStatus
{
    NSString *description;
    switch ((GSSocks4ResponseStatus)aStatus) {
        case GSSocks4ResponseStatusRequestRejected:
            description = @"request was rejected or the server failed to fulfil it";
            break;
        case GSSocks4ResponseStatusIdentdFailed:
            description = @"identd is not running or not reachable from the server";
            break;
        case GSSocks4ResponseStatusUserNotConfirmed:
            description = @"identd could not confirm the user ID string in the request";
            break;
        default:
            description = @"unknown";
            break;
    }
    description = [NSString stringWithFormat:@"SOCKS4 connnection failed, reason: %@", description];
    return [self errorWithCode:aStatus description:description];
}

- (void)parseNextChunk:(NSData *)aChunk
{
    const uint8_t *bytes = [aChunk bytes];
    if (bytes[1] != GSSocks4ResponseStatusAccessGranted) {
        NSError *error = [self errorWithResponseStatus:bytes[1]];
        [delegate parser:self encounteredError:error];
        return;
    }
    
    NSUInteger  bndPort = ntohs(*(uint16_t *)(bytes + 2));
    uint32_t    addressBytes = ntohl(*(uint32_t *)(bytes + 4));
    NSData      *addressData = [NSData dataWithBytesNoCopy:&addressBytes length:4 freeWhenDone:NO];
    NSString    *bndAddress = [self addressFromData:addressData withType:GSSocksAddressTypeIPv4];
    
    [delegate parser:self finishedWithAddress:bndAddress port:bndPort];
}

@end

#pragma GCC diagnostic pop
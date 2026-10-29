// Hardware-free fuzz harness for the HTTP parsers in pcm-sensor-server: the server-side request
// parser (HTTPRequest) and the client-side response parser (HTTPResponse). The upstream
// tests/pcm-sensor-server-fuzz.cpp needs a live PMU (MSR access) to start its server, which a
// containerised fuzzing run does not have. The bytes reach the parsers the way the real server
// gets them: through a socket stream.
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#include <cstring>

#define UNIT_TEST 1
#include "../../src/pcm-sensor-server.cpp"
#undef UNIT_TEST

namespace {

constexpr size_t kMaxInput = 100000; // fits in the default socketpair buffer, so no writer thread

template <typename Message>
void parseMessage(const uint8_t *data, size_t size)
{
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0)
        abort();
    if (size > 0 && send(sv[1], data, size, MSG_DONTWAIT) < 0)
        abort();
    shutdown(sv[1], SHUT_WR);
    {
        socketstream stream(sv[0]);
        Message msg;
        try
        {
            stream >> msg;
        }
        catch (std::exception &)
        {
            // malformed input rejected by the parser; the server's connection loop answers 400 on any std::exception
        }
    }
    close(sv[1]);
}

} // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size > kMaxInput)
        return -1;
    parseMessage<HTTPRequest>(data, size);
    parseMessage<HTTPResponse>(data, size);
    return 0;
}

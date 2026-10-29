// Fuzzes the opCode-*.txt event-configuration parser (load_events + the IIO event handler), which
// reads a file whose contents are fully attacker-controlled when users supply their own event file.
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <unistd.h>

#include "utils.h"
#include "pcm-iio-pmu.h"

using namespace pcm;

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    const char *tmpdir = getenv("TMPDIR");
    std::string path = std::string(tmpdir ? tmpdir : "/tmp") + "/opcode-fuzz-XXXXXX";
    int fd = mkstemp(&path[0]);
    if (fd < 0)
        abort();
    for (size_t off = 0; off < size;)
    {
        ssize_t n = write(fd, data + off, size - off);
        if (n <= 0)
            abort();
        off += static_cast<size_t>(n);
    }
    close(fd);

    std::map<std::string, uint32_t> opcodeFieldMap;
    fillOpcodeFieldMapForPCIeEvents(opcodeFieldMap);
    iio_evt_parse_context ctx;
    ctx.cpu_family_model = PCM_CPU_FAMILY_MODEL(6, 174);
    try
    {
        load_events(path, opcodeFieldMap, iio_evt_parse_handler, &ctx);
    }
    catch (std::invalid_argument &)
    {
        // malformed event file rejected by the parser; any other exception is reported by libFuzzer
    }
    unlink(path.c_str());
    return 0;
}

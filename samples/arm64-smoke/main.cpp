#include <algorithm>
#include <functional>
#include <iostream>
#include <numeric>
#include <string>
#include <vector>

int main(int argc, char** argv) {
    if (argc != 2 || std::string(argv[1]) != "--smoke-test") {
        std::cerr << "Usage: openarm-smoke --smoke-test\n";
        return 2;
    }

    std::vector<int> priorities{42, 91, 17, 68};
    std::sort(priorities.begin(), priorities.end(), std::greater<int>());
    if (priorities.front() != 91 ||
        std::accumulate(priorities.begin(), priorities.end(), 0) != 218) {
        std::cerr << "Core workflow failed\n";
        return 1;
    }

#if defined(_M_ARM64) || defined(__aarch64__)
    constexpr auto architecture = "arm64";
#elif defined(_M_X64) || defined(__x86_64__)
    constexpr auto architecture = "x64";
#else
    constexpr auto architecture = "other";
#endif
    std::cout << "{\"workflow\":\"priority-sort\",\"passed\":true,\"compiledArchitecture\":\""
              << architecture << "\"}\n";
    return 0;
}

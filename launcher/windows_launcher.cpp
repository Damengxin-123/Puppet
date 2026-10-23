#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <string>
#include <vector>

// 获取启动器所在目录，确保从任意工作目录双击都能找到项目。
static std::wstring project_directory() {
    std::vector<wchar_t> path(32768);
    const DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
    std::wstring result(path.data(), length);
    return result.substr(0, result.find_last_of(L"\\/"));
}

// 启动项目内的 Godot 运行环境，直接打开木偶人软件窗口。
int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    const std::wstring directory = project_directory();
    const std::wstring engine = directory + L"\\tools\\Godot\\Godot_v4.7.2-stable_win64.exe";
    const std::wstring extension = directory + L"\\bin\\puppet_native.windows.template_debug.x86_64.dll";
    if (GetFileAttributesW(engine.c_str()) == INVALID_FILE_ATTRIBUTES || GetFileAttributesW(extension.c_str()) == INVALID_FILE_ATTRIBUTES) {
        MessageBoxW(nullptr, L"运行环境尚未准备完成，请先执行 scripts/准备环境.ps1。", L"木偶人", MB_OK | MB_ICONINFORMATION);
        return 1;
    }
    const std::wstring command = L"\"" + engine + L"\" --path \"" + directory + L"\"";
    std::vector<wchar_t> command_buffer(command.begin(), command.end());
    command_buffer.push_back(L'\0');
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESHOWWINDOW;
    startup.wShowWindow = SW_SHOWNORMAL;
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(engine.c_str(), command_buffer.data(), nullptr, nullptr, FALSE, 0, nullptr, directory.c_str(), &startup, &process)) {
        MessageBoxW(nullptr, L"无法启动木偶人，请检查项目路径和 tools/Godot 中的程序。", L"木偶人", MB_OK | MB_ICONERROR);
        return 1;
    }
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return 0;
}


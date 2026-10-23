#include "puppet_animator.hpp"
#include <godot_cpp/godot.hpp>
using namespace godot;

// 在场景初始化阶段注册木偶动画核心。
static void initialize_puppet(ModuleInitializationLevel level){if(level==MODULE_INITIALIZATION_LEVEL_SCENE)ClassDB::register_class<PuppetAnimator>();}
// 对称处理模块卸载阶段。
static void uninitialize_puppet(ModuleInitializationLevel level){(void)level;}

extern "C" {
// Godot 加载动态库时调用的入口。
GDExtensionBool GDE_EXPORT puppet_library_init(GDExtensionInterfaceGetProcAddress get_proc_address,GDExtensionClassLibraryPtr library,GDExtensionInitialization* initialization){GDExtensionBinding::InitObject init(get_proc_address,library,initialization);init.register_initializer(initialize_puppet);init.register_terminator(uninitialize_puppet);init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);return init.init();}
}

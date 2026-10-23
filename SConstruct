#!/usr/bin/env python
"""构建木偶人的 C++ 动画核心及 Godot 原生扩展。"""
import os

# 复用固定版本的官方 C++ 绑定构建配置。
env = SConscript("third_party/godot-cpp/SConstruct")
env.Append(CPPPATH=["native"])
if env["platform"] == "windows":
    env.Append(CXXFLAGS=["/utf-8"])
# 所有源文件集中编译为可直接加载的扩展。
sources = Glob("native/*.cpp")
library = env.SharedLibrary("bin/puppet_native{}{}".format(env["suffix"], env["SHLIBSUFFIX"]), source=sources)
Default(library)


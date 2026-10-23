#pragma once
#include "animation_core.hpp"
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

// 向 Godot 暴露数据驱动骨架、插值和姿势求解的原生接口。
class PuppetAnimator : public godot::RefCounted {
    GDCLASS(PuppetAnimator, godot::RefCounted)
    // 每个求解器独立持有骨架与限制，不依赖全局标准人形或固定关节数量。
    std::vector<puppet::Bone> bones_ = puppet::humanoid();
protected:
    // 注册可供脚本与后续接口使用的方法。
    static void _bind_methods();
public:
    // 验证并替换当前求解器的骨架，失败时保留已有骨架。
    bool configure_rig(const godot::Array &definition);
    // 返回当前骨架的中文名称与关节参数。
    godot::Array describe_rig() const;
    // 限制整套姿势的角度并补齐缺少的关节。
    godot::PackedVector3Array clamp_pose(const godot::PackedVector3Array &pose) const;
    // 返回指定姿势的骨架空间关节位置。
    godot::PackedVector3Array evaluate_positions(const godot::PackedVector3Array &pose, godot::Vector3 root) const;
    // 返回每个关节在骨架空间中的位置和整体四元数。
    godot::Array evaluate_transforms(const godot::PackedVector3Array &pose, godot::Vector3 root) const;
    // 返回指定姿势对应的局部四元数。
    godot::Array local_rotations(const godot::PackedVector3Array &pose) const;
    // 按保持、线性或平滑模式插值关键姿势。
    godot::PackedVector3Array interpolate_pose(const godot::PackedVector3Array &a,const godot::PackedVector3Array &b,double weight,int mode) const;
    // 根据拖动目标计算保持骨长的关节旋转。
    godot::PackedVector3Array solve_ik(const godot::PackedVector3Array &pose,int joint,godot::Vector3 target,godot::Vector3 root,int chain_length=2) const;
    // 将精确样本位置转换为每秒 60000 刻度的时间码。
    int64_t sample_tick(int64_t sample,int64_t fps) const;
};


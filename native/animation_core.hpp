#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <string>
#include <vector>

namespace puppet {
// 角度换算使用的圆周率常量。
constexpr double pi = 3.14159265358979323846;

// 与显示引擎无关的三维数学向量。
struct Vec3 {
    double x = 0.0; // X 分量，空间向量使用米。
    double y = 0.0; // Y 分量，空间向量使用米。
    double z = 0.0; // Z 分量，空间向量使用米。
    // 返回向量之和。
    Vec3 operator+(const Vec3 &b) const { return {x+b.x, y+b.y, z+b.z}; }
    // 返回向量之差。
    Vec3 operator-(const Vec3 &b) const { return {x-b.x, y-b.y, z-b.z}; }
    // 返回缩放后的向量。
    Vec3 operator*(double s) const { return {x*s, y*s, z*s}; }
    // 计算点积。
    double dot(const Vec3 &b) const { return x*b.x + y*b.y + z*b.z; }
    // 计算叉积。
    Vec3 cross(const Vec3 &b) const { return {y*b.z-z*b.y, z*b.x-x*b.z, x*b.y-y*b.x}; }
    // 计算向量长度。
    double length() const { return std::sqrt(dot(*this)); }
    // 安全归一化，零向量返回零。
    Vec3 normalized() const { double n=length(); return n>1e-10 ? (*this)*(1.0/n) : Vec3{}; }
};

// 单位四元数，避免关键姿势过渡跨角度边界时跳变。
struct Quat {
    double x=0.0; // 旋转虚部分量 X。
    double y=0.0; // 旋转虚部分量 Y。
    double z=0.0; // 旋转虚部分量 Z。
    double w=1.0; // 旋转实部分量。
    // 合成两个旋转。
    Quat operator*(const Quat &b) const { return {w*b.x+x*b.w+y*b.z-z*b.y,w*b.y-x*b.z+y*b.w+z*b.x,w*b.z+x*b.y-y*b.x+z*b.w,w*b.w-x*b.x-y*b.y-z*b.z}; }
    // 返回单位四元数的逆旋转。
    Quat inverse() const { return {-x,-y,-z,w}; }
    // 将四元数归一化。
    Quat normalized() const { double n=std::sqrt(x*x+y*y+z*z+w*w); return n>1e-12 ? Quat{x/n,y/n,z/n,w/n} : Quat{}; }
    // 将旋转作用于向量。
    Vec3 rotate(const Vec3 &v) const { Vec3 q{x,y,z}; Vec3 t=q.cross(v)*2.0; return v+t*w+q.cross(t); }
    // 从 XYZ 顺序的局部欧拉角（度）建立旋转。
    static Quat from_degrees(const Vec3 &v) { double a=v.x*pi/360.0,b=v.y*pi/360.0,c=v.z*pi/360.0; return (Quat{0,0,std::sin(c),std::cos(c)}*Quat{0,std::sin(b),0,std::cos(b)}*Quat{std::sin(a),0,0,std::cos(a)}).normalized(); }
    // 将旋转转换为与输入一致的 XYZ 欧拉角（度）。
    Vec3 degrees() const { Quat q=normalized(); return {std::atan2(2*(q.w*q.x+q.y*q.z),1-2*(q.x*q.x+q.y*q.y))*180/pi,std::asin(std::clamp(2*(q.w*q.y-q.z*q.x),-1.0,1.0))*180/pi,std::atan2(2*(q.w*q.z+q.x*q.y),1-2*(q.y*q.y+q.z*q.z))*180/pi}; }
    // 计算将一个方向转向另一个方向的最短旋转。
    static Quat from_to(Vec3 a,Vec3 b) { a=a.normalized(); b=b.normalized(); double d=a.dot(b); if(d<-0.999999){Vec3 axis=a.cross({1,0,0});if(axis.length()<1e-6)axis=a.cross({0,1,0});axis=axis.normalized();return {axis.x,axis.y,axis.z,0};} Vec3 c=a.cross(b); return Quat{c.x,c.y,c.z,1+d}.normalized(); }
    // 在两个旋转之间做最短路径球面插值。
    static Quat slerp(Quat a,Quat b,double t) { double d=a.x*b.x+a.y*b.y+a.z*b.z+a.w*b.w; if(d<0){b={-b.x,-b.y,-b.z,-b.w};d=-d;} if(d>0.9995)return Quat{a.x+(b.x-a.x)*t,a.y+(b.y-a.y)*t,a.z+(b.z-a.z)*t,a.w+(b.w-a.w)*t}.normalized(); double angle=std::acos(std::clamp(d,-1.0,1.0));double s=std::sin(angle);double u=std::sin((1-t)*angle)/s,v=std::sin(t*angle)/s;return {a.x*u+b.x*v,a.y*u+b.y*v,a.z*u+b.z*v,a.w*u+b.w*v}; }
};

// 可由不同骨架体系实例化的骨骼定义，动画模式保持层级和骨长不变。
struct Bone {
    std::string id; // 自行持有稳定标识，支持运行时载入骨架。
    std::string name; // 自行持有界面显示的中文关节名称。
    int parent; // 父骨骼索引，根节点为负数。
    Vec3 offset; // 绑定姿势相对于父骨骼的位置，单位为米。
    Vec3 minimum; // 局部旋转下限，单位为度。
    Vec3 maximum; // 局部旋转上限，单位为度。
    double radius; // 外层肢体显示半径，单位为米。
    Quat rest_rotation{}; // 参考姿势的局部旋转，为手指等不同关节轴保留准确基准。
};

// 构造只读标准人形骨架，骨长和层级不能在动作模式修改。
inline const std::vector<Bone>& humanoid() {
    static const std::vector<Bone> bones={
        {"root","根节点",-1,{0,0,0},{-180,-180,-180},{180,180,180},0.03},
        {"pelvis","骨盆",0,{0,0.96,0},{-45,-70,-40},{45,70,40},0.11},
        {"spine_lower","腰部",1,{0,0.12,0},{-35,-40,-30},{35,40,30},0.11},
        {"spine_upper","上脊柱",2,{0,0.14,0},{-35,-40,-30},{35,40,30},0.12},
        {"chest","胸部",3,{0,0.14,0},{-35,-45,-30},{35,45,30},0.14},
        {"neck","颈部",4,{0,0.17,0},{-45,-65,-35},{45,65,35},0.05},
        {"head","头部",5,{0,0.16,0},{-40,-70,-35},{40,70,35},0.11},
        {"clavicle_l","左锁骨",4,{0.10,0.08,0},{-35,-40,-35},{35,40,35},0.04},
        {"upper_arm_l","左上臂",7,{0.12,0,0},{-170,-160,-170},{170,160,170},0.05},
        {"forearm_l","左前臂",8,{0.28,-0.02,0},{-85,-145,-8},{85,0,8},0.04},
        {"hand_l","左手",9,{0.25,0,0},{-65,-70,-80},{65,70,80},0.04},
        {"clavicle_r","右锁骨",4,{-0.10,0.08,0},{-35,-40,-35},{35,40,35},0.04},
        {"upper_arm_r","右上臂",11,{-0.12,0,0},{-170,-160,-170},{170,160,170},0.05},
        {"forearm_r","右前臂",12,{-0.28,-0.02,0},{-85,0,-8},{85,145,8},0.04},
        {"hand_r","右手",13,{-0.25,0,0},{-65,-70,-80},{65,70,80},0.04},
        {"thigh_l","左大腿",1,{0.10,-0.08,0},{-115,-50,-55},{60,50,55},0.065},
        {"shin_l","左小腿",15,{0,-0.42,0},{0,-5,-3},{145,5,3},0.05},
        {"foot_l","左脚",16,{0,-0.41,0},{-45,-30,-30},{60,30,30},0.05},
        {"toe_l","左脚趾",17,{0,0,0.16},{-45,-10,-10},{45,10,10},0.035},
        {"thigh_r","右大腿",1,{-0.10,-0.08,0},{-115,-50,-55},{60,50,55},0.065},
        {"shin_r","右小腿",19,{0,-0.42,0},{0,-5,-3},{145,5,3},0.05},
        {"foot_r","右脚",20,{0,-0.41,0},{-45,-30,-30},{60,30,30},0.05},
        {"toe_r","右脚趾",21,{0,0,0.16},{-45,-10,-10},{45,10,10},0.035}
    }; return bones;
}

// 一个关节在骨架空间中的求解结果。
struct JointState {
    Vec3 position; // 骨架空间位置，单位为米。
    Quat rotation; // 累积后的整体旋转。
};

// 将一个关节的局部角度限制在允许范围。
inline Vec3 clamp_joint(int index,Vec3 a,const std::vector<Bone>& rig=humanoid()) { const auto &b=rig[index];return {std::clamp(a.x,b.minimum.x,b.maximum.x),std::clamp(a.y,b.minimum.y,b.maximum.y),std::clamp(a.z,b.minimum.z,b.maximum.z)}; }

// 根据固定绑定姿势与局部旋转批量计算骨架位置。
inline std::vector<JointState> evaluate(const std::vector<Vec3>& pose,Vec3 root,const std::vector<Bone>& rig=humanoid()) { std::vector<JointState> result(rig.size());for(size_t i=0;i<rig.size();++i){Quat local=rig[i].rest_rotation*Quat::from_degrees(i<pose.size()?pose[i]:Vec3{});int p=rig[i].parent;if(p<0)result[i]={root+rig[i].offset,local};else result[i]={result[p].position+result[p].rotation.rotate(rig[i].offset),result[p].rotation*local};}return result; }

// 使用受关节限制的 CCD 求解短骨链，骨长始终保持不变。
inline std::vector<Vec3> solve_ik(std::vector<Vec3> pose,int tip,Vec3 target,Vec3 root,const std::vector<Bone>& rig=humanoid(),int chain_length=2) {
    pose.resize(rig.size());if(tip<1||tip>=int(rig.size()))return pose;
    chain_length=std::clamp(chain_length,1,32);
    for(int iteration=0;iteration<18;++iteration){auto state=evaluate(pose,root,rig);if((state[tip].position-target).length()<0.002)break;int joint=rig[tip].parent;for(int depth=0;depth<chain_length&&joint>0;++depth){state=evaluate(pose,root,rig);Vec3 a=state[tip].position-state[joint].position,b=target-state[joint].position;if(a.length()>1e-7&&b.length()>1e-7){Quat delta=Quat::from_to(a,b);int parent=rig[joint].parent;Quat pr=parent>=0?state[parent].rotation:Quat{};Quat rest=rig[joint].rest_rotation;Quat local=rest.inverse()*pr.inverse()*delta*pr*rest*Quat::from_degrees(pose[joint]);pose[joint]=clamp_joint(joint,local.degrees(),rig);}joint=rig[joint].parent;}}
    return pose;
}
}


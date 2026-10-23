#include "puppet_animator.hpp"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <unordered_set>
using namespace godot;

// 将引擎向量转换为独立数学向量。
static puppet::Vec3 to_core(Vector3 v){return {v.x,v.y,v.z};}
// 将独立数学向量转换为引擎向量。
static Vector3 to_godot(puppet::Vec3 v){return Vector3(v.x,v.y,v.z);}
// 按当前骨架数量转换姿势，缺少的关节保持零旋转。
static std::vector<puppet::Vec3> unpack(const PackedVector3Array& pose,size_t count){std::vector<puppet::Vec3> p(count);for(int i=0;i<std::min<int>(pose.size(),p.size());++i)p[i]=to_core(pose[i]);return p;}
// 将原生姿势批量返回给脚本。
static PackedVector3Array pack(const std::vector<puppet::Vec3>& pose){PackedVector3Array p;p.resize(pose.size());for(int i=0;i<int(pose.size());++i)p[i]=to_godot(pose[i]);return p;}

void PuppetAnimator::_bind_methods(){
    ClassDB::bind_method(D_METHOD("configure_rig","definition"),&PuppetAnimator::configure_rig);
    ClassDB::bind_method(D_METHOD("describe_rig"),&PuppetAnimator::describe_rig);
    ClassDB::bind_method(D_METHOD("clamp_pose","pose"),&PuppetAnimator::clamp_pose);
    ClassDB::bind_method(D_METHOD("evaluate_positions","pose","root"),&PuppetAnimator::evaluate_positions);
    ClassDB::bind_method(D_METHOD("evaluate_transforms","pose","root"),&PuppetAnimator::evaluate_transforms);
    ClassDB::bind_method(D_METHOD("local_rotations","pose"),&PuppetAnimator::local_rotations);
    ClassDB::bind_method(D_METHOD("interpolate_pose","a","b","weight","mode"),&PuppetAnimator::interpolate_pose);
    ClassDB::bind_method(D_METHOD("solve_ik","pose","joint","target","root","chain_length"),&PuppetAnimator::solve_ik,DEFVAL(2));
    ClassDB::bind_method(D_METHOD("sample_tick","sample","fps"),&PuppetAnimator::sample_tick);
}
// 完整校验后才交换骨架，所有名称均由原生对象自行持有。
bool PuppetAnimator::configure_rig(const Array& definition){
    if(definition.is_empty()||definition.size()>512)return false;
    std::vector<puppet::Bone> next;
    std::unordered_set<std::string> ids;
    for(int i=0;i<definition.size();++i){
        if(definition[i].get_type()!=Variant::DICTIONARY)return false;
        Dictionary d=definition[i];
        if(!d.has("id")||!d.has("parent")||!d.has("offset")||!d.has("minimum")||!d.has("maximum"))return false;
        if(d["offset"].get_type()!=Variant::VECTOR3||d["minimum"].get_type()!=Variant::VECTOR3||d["maximum"].get_type()!=Variant::VECTOR3)return false;
        String id=d["id"],name=d.get("name",id);
        int parent=d["parent"];
        Vector3 offset=d["offset"],minimum=d["minimum"],maximum=d["maximum"];
        double radius=d.get("radius",0.04);
        if(id.is_empty()||(i==0?parent!=-1:parent<0||parent>=i)||!offset.is_finite()||!minimum.is_finite()||!maximum.is_finite()||!std::isfinite(radius)||radius<=0)return false;
        for(int axis=0;axis<3;++axis)if(minimum[axis]>maximum[axis])return false;
        std::string native_id=id.utf8().get_data();
        if(!ids.insert(native_id).second)return false;
        Quaternion rest=d.get("rest_rotation",Quaternion());
        double norm=rest.x*rest.x+rest.y*rest.y+rest.z*rest.z+rest.w*rest.w;
        if(!std::isfinite(norm)||norm<1e-12)return false;
        next.push_back({native_id,std::string(name.utf8().get_data()),parent,to_core(offset),to_core(minimum),to_core(maximum),radius,puppet::Quat{rest.x,rest.y,rest.z,rest.w}.normalized()});
    }
    bones_.swap(next);
    return true;
}
Array PuppetAnimator::describe_rig()const{Array result;for(const auto&b:bones_){Dictionary d;d["id"]=String::utf8(b.id.c_str());d["name"]=String::utf8(b.name.c_str());d["parent"]=b.parent;d["offset"]=to_godot(b.offset);d["minimum"]=to_godot(b.minimum);d["maximum"]=to_godot(b.maximum);d["radius"]=b.radius;d["rest_rotation"]=Quaternion(b.rest_rotation.x,b.rest_rotation.y,b.rest_rotation.z,b.rest_rotation.w);result.append(d);}return result;}
PackedVector3Array PuppetAnimator::clamp_pose(const PackedVector3Array& pose)const{auto p=unpack(pose,bones_.size());for(int i=0;i<int(p.size());++i)p[i]=puppet::clamp_joint(i,p[i],bones_);return pack(p);}
PackedVector3Array PuppetAnimator::evaluate_positions(const PackedVector3Array& pose,Vector3 root)const{auto result=puppet::evaluate(unpack(pose,bones_.size()),to_core(root),bones_);PackedVector3Array positions;for(const auto &joint:result)positions.append(to_godot(joint.position));return positions;}
Array PuppetAnimator::evaluate_transforms(const PackedVector3Array& pose,Vector3 root)const{Array result;for(const auto& joint:puppet::evaluate(unpack(pose,bones_.size()),to_core(root),bones_)){Dictionary d;d["position"]=to_godot(joint.position);d["rotation"]=Quaternion(joint.rotation.x,joint.rotation.y,joint.rotation.z,joint.rotation.w);result.append(d);}return result;}
Array PuppetAnimator::local_rotations(const PackedVector3Array& pose)const{Array result;for(const auto &a:unpack(pose,bones_.size())){auto q=puppet::Quat::from_degrees(a);result.append(Quaternion(q.x,q.y,q.z,q.w));}return result;}
PackedVector3Array PuppetAnimator::interpolate_pose(const PackedVector3Array&a,const PackedVector3Array&b,double weight,int mode)const{
    auto p=unpack(a,bones_.size()),q=unpack(b,bones_.size());
    double t=std::clamp(weight,0.0,1.0);
    if(mode==0)t=t<1.0?0.0:1.0;
    else if(mode==2)t=t*t*(3-2*t);
    for(int i=0;i<int(p.size());++i){
        if(t>=1)p[i]=q[i];
        else if(t>0)p[i]=puppet::Quat::slerp(puppet::Quat::from_degrees(p[i]),puppet::Quat::from_degrees(q[i]),t).degrees();
        p[i]=puppet::clamp_joint(i,p[i],bones_);
    }
    return pack(p);
}
PackedVector3Array PuppetAnimator::solve_ik(const PackedVector3Array&pose,int joint,Vector3 target,Vector3 root,int chain_length)const{return pack(puppet::solve_ik(unpack(pose,bones_.size()),joint,to_core(target),to_core(root),bones_,chain_length));}
int64_t PuppetAnimator::sample_tick(int64_t sample,int64_t fps)const{return fps>0?int64_t(std::llround(double(sample)*60000.0/double(fps))):0;}


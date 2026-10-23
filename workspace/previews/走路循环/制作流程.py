"""通过标准 MCP 制作走路循环、播放并获取真实截图；不直接写入动画文件。"""

import asyncio
import base64
import copy
import json
import math
from pathlib import Path
import sys
import uuid

from mcp.client import ClientSession
from mcp.client.stdio import StdioServerParameters, stdio_client

# 当前软件工程和本次动画的过程记录目录。
PROJECT = Path(__file__).resolve().parents[3]
OUTPUT = Path(__file__).resolve().parent
# 标准人形完整两步所需时间，动画采用原地循环供后续角色复用。
DURATION = 1.2


def mul(a, b):
    """按 XYZW 顺序合成旋转，与软件接口使用相同约定。"""
    x,y,z,w = a
    u,v,t,s = b
    return (w*u+x*s+y*t-z*v, w*v-x*t+y*s+z*u, w*t+x*v-y*u+z*s, w*s-x*u-y*v-z*t)


def inverse(q):
    """返回单位四元数的逆旋转。"""
    return (-q[0], -q[1], -q[2], q[3])


def rotate(q, value):
    """将三维向量转换至对应的旋转空间。"""
    return mul(mul(q, (*value, 0)), inverse(q))[:3]


def quaternion(angles):
    """由参考姿势增量角建立 Rz、Ry、Rx 合成旋转。"""
    x,y,z = [math.radians(item)*0.5 for item in angles]
    return mul(mul((0,0,math.sin(z),math.cos(z)), (0,math.sin(y),0,math.cos(y))), (math.sin(x),0,0,math.cos(x)))


def euler(q):
    """转换为软件接受的 XYZ 欧拉角，仅保留关键帧所需两位小数。"""
    x,y,z,w = q
    return [round(math.degrees(value),2) for value in (
        math.atan2(2*(w*x+y*z),1-2*(x*x+y*y)),
        math.asin(max(-1,min(1,2*(w*y-z*x)))),
        math.atan2(2*(w*z+x*y),1-2*(y*y+z*z))) ]


def add(a,b):
    """相加两个米制位置向量。"""
    return tuple(x+y for x,y in zip(a,b))


def fk(bones, rotations, root):
    """根据 MCP 读到的真实参考层级计算姿势规划所需的骨架坐标。"""
    result = {}
    for bone in bones:
        local = mul(bone['rest_rotation_xyzw'], quaternion(rotations[bone['id']]))
        if bone['parent_id']:
            position, parent_rotation = result[bone['parent_id']]
            result[bone['id']] = (add(position,rotate(parent_rotation,bone['rest_translation_m'])), mul(parent_rotation,local))
        else:
            result[bone['id']] = (add(root,bone['rest_translation_m']), local)
    return result


def ease(value):
    """用平滑曲线衔接落脚、抬脚和踝关节翻转。"""
    value = max(0,min(1,value))
    return value*value*(3-2*value)


def foot_path(phase):
    """规划前六成支撑、后四成摆动的原地步态，前后步幅为四十八厘米。"""
    stride = 0.24
    if phase <= 0.6:
        z = stride*(1-2*phase/0.6)
        pitch = -12*(1-ease(phase/0.12)) if phase < 0.12 else 20*ease((phase-0.4)/0.2)
        y = 0.05 + max(0,0.16*math.sin(math.radians(pitch)))
    else:
        u = (phase-0.6)/0.4
        slope = -2*stride/0.6*0.4
        z = (2*u**3-3*u*u+1)*(-stride)+(u**3-2*u*u+u)*slope+(-2*u**3+3*u*u)*stride+(u**3-u*u)*slope
        pitch = 20*(1-ease(u))-12*ease(u)
        y = 0.05+0.16*math.sin(math.radians(20))*(1-ease(u))+0.045*math.sin(math.pi*u)**2
    return z,y,pitch


def make_pose(bones, phase):
    """结合身体重心、反向摆臂和双骨段几何规划一组完整关键姿势。"""
    lookup = {bone['id']:bone for bone in bones}
    rotations = {bone['id']:[0.0,0.0,0.0] for bone in bones}
    wave = math.cos(2*math.pi*phase)
    sway = math.sin(2*math.pi*phase)
    root = [round(0.025*sway,2),round(-0.025-0.02*math.cos(4*math.pi*phase),2),0.0]
    rotations.update({
        'pelvis':[2,round(3.5*wave,2),round(-1.2*sway,2)],
        'spine_lower':[1,0,0], 'spine_upper':[1,0,0],
        'chest':[1,round(-2.8*wave,2),round(0.8*sway,2)],
        'neck':[-2,0,0], 'head':[-2,0,0],
        'clavicle_l':[0,0,-3], 'clavicle_r':[0,0,3],
        'upper_arm_l':[0,round(18*wave,2),-82],
        'upper_arm_r':[0,round(18*wave,2),82],
        'forearm_l':[0,round(-14+4*wave,2),0],
        'forearm_r':[0,round(14+4*wave,2),0],
        'hand_l':[0,0,-3], 'hand_r':[0,0,3],
    })
    for side,offset in [('l',0),('r',0.5)]:
        z,y,pitch = foot_path((phase+offset)%1)
        state = fk(bones,rotations,root)
        hip = state[f'thigh_{side}'][0]
        parent_rotation = state['pelvis'][1]
        goal = [0.1 if side=='l' else -0.1,y,z]
        vector = rotate(inverse(parent_rotation),[goal[i]-hip[i] for i in range(3)])
        first = abs(lookup[f'shin_{side}']['rest_translation_m'][1])
        second = abs(lookup[f'foot_{side}']['rest_translation_m'][1])
        distance = math.sqrt(sum(item*item for item in vector))
        if distance > first+second:
            raise ValueError(f'规划的脚部目标超出骨长：{side}，相位 {phase}')
        knee = math.acos(max(-1,min(1,(distance*distance-first*first-second*second)/(2*first*second))))
        hip_angle = math.atan2(-vector[2],math.hypot(vector[0],vector[1]))-math.atan2(second*math.sin(knee),first+second*math.cos(knee))
        abduction = math.atan2(vector[0],-vector[1])
        rotations[f'thigh_{side}'] = [round(math.degrees(hip_angle),2),0,round(math.degrees(abduction),2)]
        rotations[f'shin_{side}'] = [round(math.degrees(knee),2),0,0]
        leg_rotation = fk(bones,rotations,root)[f'shin_{side}'][1]
        desired = quaternion([pitch,5 if side=='l' else -5,0])
        rotations[f'foot_{side}'] = euler(mul(inverse(leg_rotation),desired))
        rotations[f'toe_{side}'] = [round(-max(0,pitch)*0.65,2),0,0]
    for bone in bones:
        for axis,value in enumerate(rotations[bone['id']]):
            if not bone['limits']['minimum_deg'][axis]-0.001 <= value <= bone['limits']['maximum_deg'][axis]+0.001:
                raise ValueError(f'规划超出关节范围：{bone["id"]}，{rotations[bone["id"]]}')
    return {'rotations_deg':rotations,'root_m':root}


async def run():
    """所有软件操作均调用标准 MCP 工具，记录关键输入和真实返回结果。"""
    parameters = StdioServerParameters(command=sys.executable,args=[str(PROJECT/'mcp_service/server.py')])
    async with stdio_client(parameters) as streams:
        async with ClientSession(*streams) as session:
            await session.initialize()

            async def call(name, params=None):
                """调用工具，拒绝错误结果，并保存不含图片载荷的操作记录。"""
                result = await session.call_tool(name,params or {})
                data = result.structured_content
                with (OUTPUT/'MCP操作记录.jsonl').open('a',encoding='utf-8') as log:
                    log.write(json.dumps({'tool':name,'arguments':params or {},'result':data},ensure_ascii=False)+'\n')
                if result.is_error or not data.get('ok'):
                    raise RuntimeError(json.dumps(data,ensure_ascii=False))
                return data,result

            async def write(name, params):
                """读取最新修订后写入，保留成功请求编号供重试确认。"""
                document,_ = await call('get_document')
                values = {'document_id':document['document_id'],'expected_revision':document['revision'],'request_id':uuid.uuid4().hex,**params}
                return await call(name,values)

            rig,_ = await call('get_rig',{'rig_id':'standard_humanoid_v1'})
            poses = [make_pose(rig['rig']['bones'],index/20) for index in range(20)]
            poses.append(copy.deepcopy(poses[0]))
            state_file = OUTPUT/'动画标识.json'
            if state_file.exists():
                target = json.loads(state_file.read_text(encoding='utf-8'))
            else:
                created,_ = await write('create_clip',{'rig_id':'standard_humanoid_v1','name':'走路循环','duration_seconds':DURATION,'fps':60,'loop':True,'interpolation':'linear'})
                target = {'rig_id':created['clip']['rig_id'],'clip_id':created['clip']['clip_id']}
                state_file.write_text(json.dumps(target,ensure_ascii=False,indent=2),encoding='utf-8')
            commands = [{'op':'upsert_keyframe','time_seconds':round(index*DURATION/20,2),**pose} for index,pose in enumerate(poses)]
            result,_ = await write('apply_edit_batch',{**target,'commands':commands})
            (OUTPUT/'关键姿势规划.json').write_text(json.dumps(commands,ensure_ascii=False,indent=2),encoding='utf-8')
            print('已保存动画',json.dumps(result['clip'],ensure_ascii=False))
            validation,_ = await call('validate_clip',target)
            samples = []
            for index in range(25):
                pose,_ = await call('evaluate_pose',{**target,'time_seconds':round(index*0.05,2),'bone_ids':['foot_l','toe_l','foot_r','toe_r','hand_l','hand_r']})
                samples.append(pose)
            minimum_foot_y = min(joint['position_m'][1] for pose in samples for joint in pose['joints'] if joint['bone_id'].startswith(('foot_','toe_')))
            loop_error = max(math.dist(first['position_m'],last['position_m']) for first,last in zip(samples[0]['joints'],samples[-1]['joints']))
            (OUTPUT/'实际姿势采样.json').write_text(json.dumps(samples,ensure_ascii=False,indent=2),encoding='utf-8')
            await call('seek_animation',{**target,'time_seconds':0.0})
            await call('set_view',{'preset':'custom','yaw_deg':35,'pitch_deg':8,'target_m':[0,0.9,0],'distance_m':3.2})
            started,_ = await call('set_playback',{**target,'playing':True})
            await asyncio.sleep(0.35)
            playing,_ = await call('get_document')
            if not playing['playing'] or playing['current_tick'] == started['current_tick']:
                raise RuntimeError('播放状态没有推进。')
            frames = [{'time_seconds':round(index*0.15,2),'view':{'preset':'left','pitch_deg':4,'target_m':[0,0.9,0],'distance_m':3.2}} for index in range(8)]
            frames.extend({'time_seconds':time,'view':{'preset':'custom','yaw_deg':35,'pitch_deg':8,'target_m':[0,0.9,0],'distance_m':3.2}} for time in [0.0,0.3,0.6,0.9])
            captured,media = await call('render_preview',{**target,'width':768,'height':768,'frames':frames})
            filenames = []
            for index,block in enumerate(media.content[1:]):
                name = ('侧面' if index<8 else '斜前方')+'_%02d.png'%index
                (OUTPUT/name).write_bytes(base64.b64decode(block.data))
                filenames.append(name)
            report = {'clip':result['clip'],'joint_limits_valid':validation['valid'],'minimum_foot_joint_y_m':minimum_foot_y,'loop_position_error_m':loop_error,'playback_verified':True,'playing_time_seconds':playing['time_seconds'],'images':filenames,'output_directory':str(OUTPUT)}
            (OUTPUT/'检查结果.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
            print(json.dumps(report,ensure_ascii=False))


if __name__ == '__main__':
    asyncio.run(run())

"""通过标准 MCP 制作双脚原地跳跃，并检查蓄力、腾空和落地缓冲。"""

import asyncio
import base64
import copy
import importlib.util
import json
import math
from pathlib import Path
import sys
import uuid

from mcp.client import ClientSession
from mcp.client.stdio import StdioServerParameters, stdio_client

# 当前工程、输出目录和已有的骨架空间转换工具。
PROJECT = Path(__file__).resolve().parents[3]
OUTPUT = Path(__file__).resolve().parent
HELPER_SPEC = importlib.util.spec_from_file_location('walk_helpers', OUTPUT.parent/'走路循环/制作流程.py')
HELPERS = importlib.util.module_from_spec(HELPER_SPEC)
HELPER_SPEC.loader.exec_module(HELPERS)
# 动作总长、离地与触地时间；首尾留出站立时间便于重复预览。
DURATION = 2.40
TAKEOFF = 0.90
LANDING = 1.50
# 根节点高度轨迹；显式切线衔接起跳速度、空中抛物线与落地减速。
ROOT_TRACK = [
    (0.00,-0.02,0), (0.12,-0.02,0), (0.36,-0.14,-0.8),
    (0.60,-0.34,0), (0.70,-0.34,0), (0.78,-0.23,1.9),
    (0.84,-0.10,2.8), (0.90,0.10,2.9),
    (1.50,0.08,-2.9666667), (1.56,-0.08,-2.2),
    (1.68,-0.27,0), (1.80,-0.22,0.6), (2.10,-0.02,0),
    (2.40,-0.02,0),
]
# 姿态阶段：时间、蓄力程度、手臂向前摆角、屈肘角和根节点前后位移。
BODY_TRACK = [
    (0.00,0,0,12,0), (0.12,0,0,12,0), (0.36,0.45,-20,18,-0.04),
    (0.60,1,-40,22,-0.11), (0.70,1,-40,22,-0.11),
    (0.78,0.7,-10,25,-0.07), (0.84,0.3,40,28,-0.03),
    (0.90,0.05,105,30,0), (1.02,0.05,130,35,0),
    (1.20,0.2,110,40,0), (1.38,0.05,70,30,0),
    (1.50,0.05,45,25,0), (1.56,0.4,50,30,-0.04),
    (1.68,0.85,50,35,-0.10), (1.80,0.65,40,30,-0.08),
    (1.98,0.2,15,20,-0.02), (2.10,0,0,12,0), (2.40,0,0,12,0),
]


def smooth_track(track, time):
    """插值一组有序姿态控制值，保证各关键阶段平顺过渡。"""
    for first,last in zip(track,track[1:]):
        if first[0] <= time <= last[0]:
            u = HELPERS.ease((time-first[0])/(last[0]-first[0]))
            return [a+(b-a)*u for a,b in zip(first[1:],last[1:])]
    return list(track[0][1:] if time<track[0][0] else track[-1][1:])


def root_height(time):
    """空中按抛物线升降，其余阶段按指定速度完成下蹲、发力和缓冲。"""
    if TAKEOFF <= time <= LANDING:
        u = (time-TAKEOFF)/(LANDING-TAKEOFF)
        return 0.10-0.02*u+4*0.44*u*(1-u)
    for first,last in zip(ROOT_TRACK,ROOT_TRACK[1:]):
        if first[0] <= time <= last[0]:
            length = last[0]-first[0]
            u = (time-first[0])/length
            return ((2*u**3-3*u*u+1)*first[1]+(u**3-2*u*u+u)*length*first[2]
                    +(-2*u**3+3*u*u)*last[1]+(u**3-u*u)*length*last[2])
    return ROOT_TRACK[-1][1]


def foot_target(time, height):
    """支撑时保持脚底或脚尖着地，空中抬脚收腿，落地后平顺放下脚跟。"""
    if TAKEOFF < time < LANDING:
        rise,pitch,z = smooth_track([
            (0.90,0.055+0.16*math.sin(math.radians(50))-0.10,50,0.05+0.16*(1-math.cos(math.radians(50)))),
            (1.02,0.20,35,0.06), (1.20,0.32,15,0.02), (1.38,0.18,20,0.04),
            (1.50,0.055+0.16*math.sin(math.radians(40))-0.08,40,0.05+0.16*(1-math.cos(math.radians(40)))),
        ],time)
        return height+rise,z,pitch
    if time <= TAKEOFF:
        pitch = 50*HELPERS.ease((time-0.78)/0.12)
    else:
        pitch = 40*(1-HELPERS.ease((time-LANDING)/0.06))
    return 0.055+0.16*math.sin(math.radians(pitch)),0.05+0.16*(1-math.cos(math.radians(pitch))),pitch


def make_pose(bones, time):
    """利用实际骨长求解双腿，将摆臂和躯干姿态组成完整跳跃关键姿势。"""
    lookup = {bone['id']:bone for bone in bones}
    angles = {bone['id']:[0.0,0.0,0.0] for bone in bones}
    crouch,arm,elbow,root_z = smooth_track(BODY_TRACK,time)
    root = [0.0,round(root_height(time),2),round(root_z,2)]
    angles.update({
        'pelvis':[round(8*crouch,2),0,0],
        'spine_lower':[round(7*crouch,2),0,0],
        'spine_upper':[round(7*crouch,2),0,0],
        'chest':[round(1+5*crouch,2),0,0],
        'neck':[round(-12*crouch,2),0,0],
        'head':[round(-1-10*crouch,2),0,0],
        'clavicle_l':[0,0,-3], 'clavicle_r':[0,0,3],
        'upper_arm_l':[0,round(-arm,2),-82],
        'upper_arm_r':[0,round(arm,2),82],
        'forearm_l':[0,round(-elbow,2),0],
        'forearm_r':[0,round(elbow,2),0],
        'hand_l':[0,0,-3], 'hand_r':[0,0,3],
    })
    y,z,pitch = foot_target(time,root[1])
    for side,sign in [('l',1),('r',-1)]:
        state = HELPERS.fk(bones,angles,root)
        hip = state[f'thigh_{side}'][0]
        parent_rotation = state['pelvis'][1]
        goal = [0.13*sign,y,z]
        vector = HELPERS.rotate(HELPERS.inverse(parent_rotation),[goal[i]-hip[i] for i in range(3)])
        first = abs(lookup[f'shin_{side}']['rest_translation_m'][1])
        second = abs(lookup[f'foot_{side}']['rest_translation_m'][1])
        distance = math.sqrt(sum(value*value for value in vector))
        if distance > first+second:
            raise ValueError(f'脚部目标超出骨长：{side}，时间 {time}，距离 {distance}')
        knee = math.acos(max(-1,min(1,(distance*distance-first*first-second*second)/(2*first*second))))
        hip_angle = math.atan2(-vector[2],math.hypot(vector[0],vector[1]))-math.atan2(second*math.sin(knee),first+second*math.cos(knee))
        angles[f'thigh_{side}'] = [round(math.degrees(hip_angle),2),0,round(math.degrees(math.atan2(vector[0],-vector[1])),2)]
        angles[f'shin_{side}'] = [round(math.degrees(knee),2),0,0]
        leg_rotation = HELPERS.fk(bones,angles,root)[f'shin_{side}'][1]
        angles[f'foot_{side}'] = HELPERS.euler(HELPERS.mul(HELPERS.inverse(leg_rotation),HELPERS.quaternion([pitch,0,0])))
        angles[f'toe_{side}'] = [round(-min(35,max(0,pitch)*0.65),2),0,0]
    for bone in bones:
        for axis,value in enumerate(angles[bone['id']]):
            if not bone['limits']['minimum_deg'][axis]-0.001 <= value <= bone['limits']['maximum_deg'][axis]+0.001:
                raise ValueError(f'关节超限：{bone["id"]}，时间 {time}，{angles[bone["id"]]}')
    return {'rotations_deg':angles,'root_m':root}


async def run():
    """经 MCP 保存动画、检查实际姿势、播放并获取各阶段的真实截图。"""
    parameters = StdioServerParameters(command=sys.executable,args=[str(PROJECT/'mcp_service/server.py')])
    async with stdio_client(parameters) as streams:
        async with ClientSession(*streams) as session:
            await session.initialize()

            async def call(name, params=None):
                """记录工具参数及结构化结果，遇到错误立即停止后续操作。"""
                result = await session.call_tool(name,params or {})
                data = result.structured_content
                with (OUTPUT/'MCP操作记录.jsonl').open('a',encoding='utf-8') as log:
                    log.write(json.dumps({'tool':name,'arguments':params or {},'result':data},ensure_ascii=False)+'\n')
                if result.is_error or not data or not data.get('ok'):
                    raise RuntimeError(json.dumps(data,ensure_ascii=False))
                return data,result

            async def write(name, params):
                """基于最新文档修订提交修改，保留可追溯的请求编号。"""
                document,_ = await call('get_document')
                return await call(name,{'document_id':document['document_id'],'expected_revision':document['revision'],'request_id':uuid.uuid4().hex,**params})

            original,_ = await call('get_document')
            if original['draft_dirty']:
                raise RuntimeError('当前存在未保存的手动姿势，需要先保留该姿势。')
            rig,_ = await call('get_rig',{'rig_id':'standard_humanoid_v1'})
            (OUTPUT/'骨骼数据.json').write_text(json.dumps(rig,ensure_ascii=False,indent=2),encoding='utf-8')
            times = sorted({round(index*0.06,2) for index in range(41)}|{0.86,0.88,1.52,1.54,1.58})
            poses = [make_pose(rig['rig']['bones'],time) for time in times]
            poses[-1] = copy.deepcopy(poses[0])
            state_file = OUTPUT/'动画标识.json'
            if state_file.exists():
                target = json.loads(state_file.read_text(encoding='utf-8'))
            else:
                created,_ = await write('create_clip',{'rig_id':'standard_humanoid_v1','name':'跳跃','duration_seconds':DURATION,'fps':60,'loop':True,'interpolation':'linear'})
                target = {'rig_id':created['clip']['rig_id'],'clip_id':created['clip']['clip_id']}
                state_file.write_text(json.dumps(target,ensure_ascii=False,indent=2),encoding='utf-8')
            commands = [{'op':'upsert_keyframe','time_seconds':time,**pose} for time,pose in zip(times,poses)]
            result,_ = await write('apply_edit_batch',{**target,'commands':commands})
            (OUTPUT/'关键姿势规划.json').write_text(json.dumps(commands,ensure_ascii=False,indent=2),encoding='utf-8')
            print('已保存跳跃',json.dumps(result['clip'],ensure_ascii=False),flush=True)
            validation,_ = await call('validate_clip',target)
            samples = []
            check_times = sorted({0,0.15,0.33,0.60,0.69,0.81,0.85,0.87,0.89,0.90,0.93,1.05,1.20,1.35,1.47,1.49,1.50,1.51,1.53,1.55,1.57,1.59,1.68,1.89,2.10,2.40})
            for time in check_times:
                sample,_ = await call('evaluate_pose',{**target,'time_seconds':time,'bone_ids':['pelvis','foot_l','toe_l','foot_r','toe_r','hand_l','hand_r']})
                samples.append(sample)
            (OUTPUT/'实际姿势采样.json').write_text(json.dumps(samples,ensure_ascii=False,indent=2),encoding='utf-8')
            minimum_foot_y = min(joint['position_m'][1] for sample in samples for joint in sample['joints'] if joint['bone_id'].startswith(('foot_','toe_')))
            loop_error = max(math.dist(a['position_m'],b['position_m']) for a,b in zip(samples[0]['joints'],samples[-1]['joints']))
            apex = next(sample for sample in samples if abs(sample['time_seconds']-1.2)<0.001)
            airborne_clearance = min(joint['position_m'][1] for joint in apex['joints'] if joint['bone_id'].startswith(('foot_','toe_')))
            await call('seek_animation',{**target,'time_seconds':0.0})
            await call('set_view',{'preset':'custom','yaw_deg':35,'pitch_deg':6,'target_m':[0,1.2,0],'distance_m':4.1})
            started,_ = await call('set_playback',{**target,'playing':True})
            await asyncio.sleep(0.3)
            playing,_ = await call('get_document')
            if not playing['playing'] or playing['current_tick']==started['current_tick']:
                raise RuntimeError('动画播放没有推进。')
            stages = [('准备站姿',0),('下蹲蓄力',0.60),('起跳蹬地',0.90),('腾空收腿',1.20),('触地',1.50),('落地缓冲',1.68)]
            frames = [{'time_seconds':time,'view':{'preset':'left','pitch_deg':4,'target_m':[0,1.2,0],'distance_m':4.1}} for name,time in stages]
            frames.extend({'time_seconds':time,'view':{'preset':'custom','yaw_deg':35,'pitch_deg':6,'target_m':[0,1.2,0],'distance_m':4.1}} for name,time in stages)
            captured,media = await call('render_preview',{**target,'width':768,'height':768,'frames':frames})
            filenames = []
            for index,block in enumerate(media.content[1:]):
                name = ('侧面_' if index<6 else '斜前方_')+stages[index%6][0]+'.png'
                (OUTPUT/name).write_bytes(base64.b64decode(block.data))
                filenames.append(name)
            final,_ = await call('get_document')
            report = {'clip':result['clip'],'joint_limits_valid':validation['valid'],'minimum_foot_joint_y_m':minimum_foot_y,'apex_minimum_foot_joint_y_m':airborne_clearance,'loop_position_error_m':loop_error,'playback_verified':True,'final_playing':final['playing'],'playback_speed':final['playback_speed'],'original_clips_preserved':all(any(clip['clip_id']==old['clip_id'] and clip['clip_revision']==old['clip_revision'] for clip in final['clips']) for old in original['clips'] if old['clip_id']!=target['clip_id']),'stages':stages,'images':filenames}
            (OUTPUT/'检查结果.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
            print(json.dumps(report,ensure_ascii=False),flush=True)


if __name__ == '__main__':
    asyncio.run(run())

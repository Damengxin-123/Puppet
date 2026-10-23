"""通过标准 MCP 制作原地奔跑动画，播放并保存真实视口截图。"""

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

# 当前工程、过程记录目录与标准人形步态规划工具。
PROJECT = Path(__file__).resolve().parents[3]
OUTPUT = Path(__file__).resolve().parent
HELPER_SPEC = importlib.util.spec_from_file_location('walk_helpers', OUTPUT.parent/'走路循环/制作流程.py')
HELPERS = importlib.util.module_from_spec(HELPER_SPEC)
HELPER_SPEC.loader.exec_module(HELPERS)
# 一个完整左右脚循环的时长，以及每隔 0.03 秒保存的关键姿势数量。
DURATION = 0.72
INTERVALS = 24
# 相位、脚踝前后位置、脚踝高度和脚掌俯仰角；支撑后进入腾空收腿阶段。
FOOT_SAMPLES = [
    (0.00, 0.26, 0.055, -4), (0.10, 0.11, 0.055, 0),
    (0.22, -0.07, 0.065, 4), (0.32, -0.22, 0.12, 24),
    (0.38, -0.31, 0.16, 40), (0.44, -0.36, 0.28, 65),
    (0.52, -0.28, 0.42, 75), (0.62, -0.08, 0.44, 65),
    (0.74, 0.19, 0.34, 28), (0.84, 0.32, 0.24, 8),
    (0.90, 0.34, 0.17, 0), (0.96, 0.31, 0.115, -4),
    (1.00, 0.26, 0.055, -4),
]


def foot_path(phase):
    """使用周期三次插值连接脚部轨迹，支撑期保持稳定的向后运动。"""
    samples = FOOT_SAMPLES[:-1]
    result = []
    for index, start in enumerate(samples):
        end = FOOT_SAMPLES[index+1]
        if start[0] <= phase <= end[0]:
            previous = list(samples[index-1])
            following = list(FOOT_SAMPLES[index+2] if index+2<len(FOOT_SAMPLES) else samples[1])
            if index == 0:
                previous[0] -= 1
            if index+2 >= len(FOOT_SAMPLES):
                following[0] += 1
            length = end[0]-start[0]
            u = (phase-start[0])/length
            for axis in (1,2,3):
                first_slope = (end[axis]-previous[axis])/(end[0]-previous[0])
                last_slope = (following[axis]-start[axis])/(following[0]-start[0])
                # 支撑阶段固定脚踝高度，落脚前后使用水平切线避免穿地。
                if axis == 2 and start[0] <= 0.1:
                    first_slope = 0
                if axis == 2 and (end[0] <= 0.1 or end[0] == 1):
                    last_slope = 0
                result.append((2*u**3-3*u*u+1)*start[axis] + (u**3-2*u*u+u)*length*first_slope
                              +(-2*u**3+3*u*u)*end[axis] + (u**3-u*u)*length*last_slope)
            return result
    raise ValueError('奔跑相位必须位于零到一之间。')


def make_pose(bones, phase):
    """用实际骨长规划腿部 IK，并组合前倾、屈肘摆臂和周期重心起伏。"""
    lookup = {bone['id']:bone for bone in bones}
    angles = {bone['id']:[0.0,0.0,0.0] for bone in bones}
    wave = math.cos(2*math.pi*phase)
    sway = math.sin(2*math.pi*phase)
    root = [round(0.015*sway,2),round(-0.06-0.08*math.cos(4*math.pi*(phase-0.12)),2),0.0]
    angles.update({
        'pelvis':[6,round(6*wave,2),round(-1.5*sway,2)],
        'spine_lower':[3,0,0], 'spine_upper':[2,0,0],
        'chest':[2,round(-10*wave,2),round(sway,2)],
        'neck':[-5,0,0], 'head':[-6,0,0],
        'clavicle_l':[0,0,-3], 'clavicle_r':[0,0,3],
        'upper_arm_l':[0,round(32*wave,2),-80],
        'upper_arm_r':[0,round(32*wave,2),80],
        'forearm_l':[0,round(-85+10*wave,2),0],
        'forearm_r':[0,round(85+10*wave,2),0],
        'hand_l':[0,-5,-3], 'hand_r':[0,5,3],
    })
    for side, offset in [('l',0),('r',0.5)]:
        z,y,pitch = foot_path((phase+offset)%1)
        state = HELPERS.fk(bones,angles,root)
        hip = state[f'thigh_{side}'][0]
        parent_rotation = state['pelvis'][1]
        goal = [0.1 if side=='l' else -0.1,y,z]
        vector = HELPERS.rotate(HELPERS.inverse(parent_rotation),[goal[i]-hip[i] for i in range(3)])
        first = abs(lookup[f'shin_{side}']['rest_translation_m'][1])
        second = abs(lookup[f'foot_{side}']['rest_translation_m'][1])
        distance = math.sqrt(sum(item*item for item in vector))
        if distance > first+second:
            raise ValueError(f'脚部超出骨长：{side}，相位 {phase}，距离 {distance}')
        knee = math.acos(max(-1,min(1,(distance*distance-first*first-second*second)/(2*first*second))))
        hip_angle = math.atan2(-vector[2],math.hypot(vector[0],vector[1]))-math.atan2(second*math.sin(knee),first+second*math.cos(knee))
        abduction = math.atan2(vector[0],-vector[1])
        angles[f'thigh_{side}'] = [round(math.degrees(hip_angle),2),0,round(math.degrees(abduction),2)]
        angles[f'shin_{side}'] = [round(math.degrees(knee),2),0,0]
        leg_rotation = HELPERS.fk(bones,angles,root)[f'shin_{side}'][1]
        desired = HELPERS.quaternion([pitch,3 if side=='l' else -3,0])
        angles[f'foot_{side}'] = HELPERS.euler(HELPERS.mul(HELPERS.inverse(leg_rotation),desired))
        angles[f'toe_{side}'] = [round(-min(35,max(0,pitch)*0.65),2),0,0]
    for bone in bones:
        for axis,value in enumerate(angles[bone['id']]):
            if not bone['limits']['minimum_deg'][axis]-0.001 <= value <= bone['limits']['maximum_deg'][axis]+0.001:
                raise ValueError(f'超出关节范围：{bone["id"]}，相位 {phase}，{angles[bone["id"]]}')
    return {'rotations_deg':angles,'root_m':root}


async def run():
    """创建动画、写入关键帧、回读姿势并播放截图，所有软件操作经标准 MCP 完成。"""
    parameters = StdioServerParameters(command=sys.executable,args=[str(PROJECT/'mcp_service/server.py')])
    async with stdio_client(parameters) as streams:
        async with ClientSession(*streams) as session:
            await session.initialize()

            async def call(name, params=None):
                """调用工具并保存无图片载荷的操作日志，工具报错时立即停止。"""
                result = await session.call_tool(name,params or {})
                data = result.structured_content
                with (OUTPUT/'MCP操作记录.jsonl').open('a',encoding='utf-8') as log:
                    log.write(json.dumps({'tool':name,'arguments':params or {},'result':data},ensure_ascii=False)+'\n')
                if result.is_error or not data or not data.get('ok'):
                    raise RuntimeError(json.dumps(data,ensure_ascii=False))
                return data,result

            async def write(name, params):
                """按当前文档修订提交修改，避免覆盖其他编辑。"""
                document,_ = await call('get_document')
                values = {'document_id':document['document_id'],'expected_revision':document['revision'],'request_id':uuid.uuid4().hex,**params}
                return await call(name,values)

            original,_ = await call('get_document')
            if original['draft_dirty']:
                raise RuntimeError('当前存在未保存的手动姿势，请先保留该姿势。')
            rig,_ = await call('get_rig',{'rig_id':'standard_humanoid_v1'})
            (OUTPUT/'骨骼数据.json').write_text(json.dumps(rig,ensure_ascii=False,indent=2),encoding='utf-8')
            poses = [make_pose(rig['rig']['bones'],index/INTERVALS) for index in range(INTERVALS)]
            poses.append(copy.deepcopy(poses[0]))
            state_file = OUTPUT/'动画标识.json'
            if state_file.exists():
                target = json.loads(state_file.read_text(encoding='utf-8'))
            else:
                created,_ = await write('create_clip',{'rig_id':'standard_humanoid_v1','name':'奔跑循环','duration_seconds':DURATION,'fps':60,'loop':True,'interpolation':'linear'})
                target = {'rig_id':created['clip']['rig_id'],'clip_id':created['clip']['clip_id']}
                state_file.write_text(json.dumps(target,ensure_ascii=False,indent=2),encoding='utf-8')
            commands = [{'op':'upsert_keyframe','time_seconds':round(index*DURATION/INTERVALS,2),**pose} for index,pose in enumerate(poses)]
            result,_ = await write('apply_edit_batch',{**target,'commands':commands})
            (OUTPUT/'关键姿势规划.json').write_text(json.dumps(commands,ensure_ascii=False,indent=2),encoding='utf-8')
            print('已保存动画',json.dumps(result['clip'],ensure_ascii=False),flush=True)
            validation,_ = await call('validate_clip',target)
            samples = []
            for index in range(25):
                sample,_ = await call('evaluate_pose',{**target,'time_seconds':round(index*0.03,2),'bone_ids':['foot_l','toe_l','foot_r','toe_r','hand_l','hand_r']})
                samples.append(sample)
            minimum_foot_y = min(joint['position_m'][1] for sample in samples for joint in sample['joints'] if joint['bone_id'].startswith(('foot_','toe_')))
            flight_times = [sample['time_seconds'] for sample in samples if min(joint['position_m'][1] for joint in sample['joints'] if joint['bone_id'].startswith(('foot_','toe_'))) > 0.1]
            loop_error = max(math.dist(first['position_m'],last['position_m']) for first,last in zip(samples[0]['joints'],samples[-1]['joints']))
            (OUTPUT/'实际姿势采样.json').write_text(json.dumps(samples,ensure_ascii=False,indent=2),encoding='utf-8')
            await call('seek_animation',{**target,'time_seconds':0.0})
            await call('set_view',{'preset':'custom','yaw_deg':35,'pitch_deg':8,'target_m':[0,0.9,0],'distance_m':3.2})
            started,_ = await call('set_playback',{**target,'playing':True})
            await asyncio.sleep(0.25)
            playing,_ = await call('get_document')
            if not playing['playing'] or playing['current_tick'] == started['current_tick']:
                raise RuntimeError('播放状态没有推进。')
            frames = [{'time_seconds':round(index*0.09,2),'view':{'preset':'left','pitch_deg':4,'target_m':[0,0.9,0],'distance_m':3.2}} for index in range(8)]
            frames.extend({'time_seconds':time,'view':{'preset':'custom','yaw_deg':35,'pitch_deg':8,'target_m':[0,0.9,0],'distance_m':3.2}} for time in [0,0.18,0.30,0.54])
            captured,media = await call('render_preview',{**target,'width':768,'height':768,'frames':frames})
            filenames = []
            for index,block in enumerate(media.content[1:]):
                name = ('侧面' if index<8 else '斜前方')+'_%02d.png'%index
                (OUTPUT/name).write_bytes(base64.b64decode(block.data))
                filenames.append(name)
            final,_ = await call('get_document')
            report = {'clip':result['clip'],'joint_limits_valid':validation['valid'],'minimum_foot_joint_y_m':minimum_foot_y,'flight_sample_times_seconds':flight_times,'loop_position_error_m':loop_error,'playback_verified':True,'final_playing':final['playing'],'original_clips_preserved':all(any(clip['clip_id']==old['clip_id'] and clip['clip_revision']==old['clip_revision'] for clip in final['clips']) for old in original['clips'] if old['clip_id']!=target['clip_id']),'images':filenames}
            (OUTPUT/'检查结果.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
            print(json.dumps(report,ensure_ascii=False),flush=True)


if __name__ == '__main__':
    asyncio.run(run())

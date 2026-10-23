"""通过标准 MCP 制作站立转左手持盾、右手后置武器的弓步防御过渡。"""

import asyncio
import base64
import importlib.util
import json
import math
from pathlib import Path
import sys
import uuid

from mcp.client import ClientSession
from mcp.client.stdio import StdioServerParameters, stdio_client

# 当前工程和动作记录目录，以及已有骨架空间转换工具。
PROJECT = Path(__file__).resolve().parents[3]
OUTPUT = Path(__file__).resolve().parent
HELPER_SPEC = importlib.util.spec_from_file_location('walk_helpers', OUTPUT.parent/'走路循环/制作流程.py')
HELPERS = importlib.util.module_from_spec(HELPER_SPEC)
HELPER_SPEC.loader.exec_module(HELPERS)
# 单次进入防御的动画总长；后段保持姿态，不自动返回站立。
DURATION = 2.20
# 左脚迈步与重心前移时刻，过渡结束后保留观察时间。
KEY_TIMES = [0,0.10,0.18,0.26,0.34,0.42,0.50,0.58,0.66,0.74,0.82,0.90,0.98,1.06,1.14,1.22,1.30,1.60,2.20]


def progress(time, start, end):
    """返回阶段内平顺的零到一进度。"""
    return HELPERS.ease((time-start)/(end-start))


def make_pose(bones, time):
    """组合迈步、重心转移、盾臂上提和后手持柄，并用骨长约束双脚位置。"""
    lookup = {bone['id']:bone for bone in bones}
    angles = {bone['id']:[0.0,0.0,0.0] for bone in bones}
    body = progress(time,0.16,1.20)
    step = progress(time,0.18,0.82)
    shield = progress(time,0.12,0.88)
    weapon = progress(time,0.20,1.00)
    shift = math.sin(math.pi*progress(time,0.10,0.82))
    root = [round(0.02*body-0.025*shift,2),round(-0.02-0.17*body**1.4,2),round(0.60*body,2)]
    angles.update({
        'pelvis':[round(3*body,2),round(-20*body,2),0],
        'spine_lower':[round(2*body,2),0,0],
        'spine_upper':[round(body,2),round(-5*body,2),0],
        'chest':[round(1+body,2),round(-5*body,2),0],
        'neck':[round(-3*body,2),round(10*body,2),0],
        'head':[round(-1-3*body,2),round(20*body,2),0],
        'clavicle_l':[0,0,-3], 'clavicle_r':[0,0,3],
        'upper_arm_l':[0,round(-50*shield,2),round(-82+17*shield,2)],
        'forearm_l':[0,round(-12-78*shield,2),0],
        'hand_l':[round(15*shield,2),round(-5*shield,2),round(-3-7*shield,2)],
        'upper_arm_r':[round(-90*weapon,2),round(-40*weapon,2),round(82-17*weapon,2)],
        'forearm_r':[0,round(12+93*weapon,2),0],
        'hand_r':[round(-10*weapon,2),round(10*weapon,2),round(3+12*weapon,2)],
    })
    for side in ['l','r']:
        if side=='l':
            y = 0.055+0.10*math.sin(math.pi*step)**2
            z = 0.05+0.75*step
            x = 0.13+0.04*step
            pitch = -8*math.sin(math.pi*step)
            yaw = 0
        else:
            x,y,z,pitch,yaw = -0.13,0.055,0.05,0,-25*body
        state = HELPERS.fk(bones,angles,root)
        hip = state[f'thigh_{side}'][0]
        parent_rotation = state['pelvis'][1]
        vector = HELPERS.rotate(HELPERS.inverse(parent_rotation),[goal-current for goal,current in zip([x,y,z],hip)])
        first = abs(lookup[f'shin_{side}']['rest_translation_m'][1])
        second = abs(lookup[f'foot_{side}']['rest_translation_m'][1])
        distance = math.sqrt(sum(value*value for value in vector))
        if distance>first+second:
            raise ValueError(f'脚部目标超出骨长：{side}，时间 {time}，距离 {distance}')
        knee = math.acos(max(-1,min(1,(distance*distance-first*first-second*second)/(2*first*second))))
        hip_angle = math.atan2(-vector[2],math.hypot(vector[0],vector[1]))-math.atan2(second*math.sin(knee),first+second*math.cos(knee))
        angles[f'thigh_{side}'] = [round(math.degrees(hip_angle),2),0,round(math.degrees(math.atan2(vector[0],-vector[1])),2)]
        angles[f'shin_{side}'] = [round(math.degrees(knee),2),0,0]
        leg_rotation = HELPERS.fk(bones,angles,root)[f'shin_{side}'][1]
        angles[f'foot_{side}'] = HELPERS.euler(HELPERS.mul(HELPERS.inverse(leg_rotation),HELPERS.quaternion([pitch,yaw,0])))
    for bone in bones:
        for axis,value in enumerate(angles[bone['id']]):
            if not bone['limits']['minimum_deg'][axis]-0.001 <= value <= bone['limits']['maximum_deg'][axis]+0.001:
                raise ValueError(f'关节超限：{bone["id"]}，时间 {time}，{angles[bone["id"]]}')
    return {'rotations_deg':angles,'root_m':root}


async def run():
    """通过 MCP 创建和保存过渡动画，回读实际姿势，播放后停在防御姿态。"""
    parameters = StdioServerParameters(command=sys.executable,args=[str(PROJECT/'mcp_service/server.py')])
    async with stdio_client(parameters) as streams:
        async with ClientSession(*streams) as session:
            await session.initialize()

            async def call(name, params=None):
                """执行工具并记录参数和结果，不把图片载荷重复写入日志。"""
                result = await session.call_tool(name,params or {})
                data = result.structured_content
                with (OUTPUT/'MCP操作记录.jsonl').open('a',encoding='utf-8') as log:
                    log.write(json.dumps({'tool':name,'arguments':params or {},'result':data},ensure_ascii=False)+'\n')
                if result.is_error or not data or not data.get('ok'):
                    raise RuntimeError(json.dumps(data,ensure_ascii=False))
                return data,result

            async def write(name, params):
                """基于软件最新修订写入，避免覆盖其他编辑。"""
                document,_ = await call('get_document')
                return await call(name,{'document_id':document['document_id'],'expected_revision':document['revision'],'request_id':uuid.uuid4().hex,**params})

            original,_ = await call('get_document')
            if original['draft_dirty']:
                raise RuntimeError('当前存在未保存的手动姿势，需要先保留该姿势。')
            rig,_ = await call('get_rig',{'rig_id':'standard_humanoid_v1'})
            (OUTPUT/'骨骼数据.json').write_text(json.dumps(rig,ensure_ascii=False,indent=2),encoding='utf-8')
            poses = [make_pose(rig['rig']['bones'],time) for time in KEY_TIMES]
            state_file = OUTPUT/'动画标识.json'
            if state_file.exists():
                target = json.loads(state_file.read_text(encoding='utf-8'))
            else:
                created,_ = await write('create_clip',{'rig_id':'standard_humanoid_v1','name':'站立转持盾弓步防御','duration_seconds':DURATION,'fps':60,'loop':False,'interpolation':'linear'})
                target = {'rig_id':created['clip']['rig_id'],'clip_id':created['clip']['clip_id']}
                state_file.write_text(json.dumps(target,ensure_ascii=False,indent=2),encoding='utf-8')
            commands = [{'op':'upsert_keyframe','time_seconds':time,**pose} for time,pose in zip(KEY_TIMES,poses)]
            edited,_ = await write('apply_edit_batch',{**target,'commands':commands})
            (OUTPUT/'关键姿势规划.json').write_text(json.dumps(commands,ensure_ascii=False,indent=2),encoding='utf-8')
            print('已保存动画',json.dumps(edited['clip'],ensure_ascii=False),flush=True)
            validation,_ = await call('validate_clip',target)
            samples = []
            for time in [0,0.18,0.22,0.30,0.38,0.46,0.54,0.62,0.70,0.78,0.82,0.86,0.94,1.02,1.10,1.20,1.30,2.20]:
                sample,_ = await call('evaluate_pose',{**target,'time_seconds':time,'bone_ids':['pelvis','chest','head','forearm_l','forearm_r','hand_l','hand_r','shin_l','shin_r','foot_l','toe_l','foot_r','toe_r']})
                samples.append(sample)
            (OUTPUT/'实际姿势采样.json').write_text(json.dumps(samples,ensure_ascii=False,indent=2),encoding='utf-8')
            last = {joint['bone_id']:joint for joint in samples[-1]['joints']}
            minimum_foot_y = min(joint['position_m'][1] for sample in samples for joint in sample['joints'] if joint['bone_id'].startswith(('foot_','toe_')))
            planted_right_drift = max(math.dist(next(j for j in sample['joints'] if j['bone_id']=='foot_r')['position_m'],next(j for j in samples[0]['joints'] if j['bone_id']=='foot_r')['position_m']) for sample in samples)
            await call('seek_animation',{**target,'time_seconds':0.0})
            await call('set_view',{'preset':'custom','yaw_deg':35,'pitch_deg':6,'target_m':[0,0.85,0.35],'distance_m':3.3})
            started,_ = await call('set_playback',{**target,'playing':True})
            await asyncio.sleep(0.3)
            playing,_ = await call('get_document')
            if not playing['playing'] or playing['current_tick']==started['current_tick']:
                raise RuntimeError('动画播放没有推进。')
            captures = [
                ('侧面_站立',0,'left'),('侧面_迈步举盾',0.50,'left'),('侧面_弓步防御',1.30,'left'),
                ('右侧_后手持柄',1.30,'right'),('正面_防御',1.30,'front'),
                ('斜前方_防御',1.30,'custom'),('斜后方_防御',1.30,'back'),
            ]
            frames = [{'time_seconds':time,'view':{'preset':preset,'pitch_deg':6,'target_m':[0,0.85,0.35],'distance_m':3.3,**({'yaw_deg':35} if preset=='custom' else {})}} for name,time,preset in captures]
            captured,media = await call('render_preview',{**target,'width':768,'height':768,'frames':frames})
            filenames = []
            for (name,time,preset),block in zip(captures,media.content[1:]):
                filename = name+'.png'
                (OUTPUT/filename).write_bytes(base64.b64decode(block.data))
                filenames.append(filename)
            # 只等待本次单次动作自然结束，随后保留最终防御姿势供用户查看。
            await asyncio.sleep(max(0.0,(DURATION-playing['time_seconds'])/max(playing['playback_speed'],0.1))+0.1)
            final,_ = await call('get_document')
            report = {'clip':edited['clip'],'joint_limits_valid':validation['valid'],'minimum_foot_joint_y_m':minimum_foot_y,'planted_right_foot_drift_m':planted_right_drift,'left_hand_in_front_of_chest':last['hand_l']['position_m'][2]>last['chest']['position_m'][2],'right_hand_behind_chest':last['hand_r']['position_m'][2]<last['chest']['position_m'][2],'forward_left_foot_distance_m':last['foot_l']['position_m'][2]-last['foot_r']['position_m'][2],'end_pose_joints':last,'playback_verified':True,'final_playing':final['playing'],'final_time_seconds':final['time_seconds'],'original_clips_preserved':all(any(clip['clip_id']==old['clip_id'] and clip['clip_revision']==old['clip_revision'] for clip in final['clips']) for old in original['clips'] if old['clip_id']!=target['clip_id']),'images':filenames}
            (OUTPUT/'检查结果.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
            print(json.dumps({key:value for key,value in report.items() if key!='end_pose_joints'},ensure_ascii=False),flush=True)


if __name__ == '__main__':
    asyncio.run(run())

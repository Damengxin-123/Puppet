"""通过标准 MCP 制作拄杖站立转前指施法，并记录可用于挂载法杖的握柄方向。"""

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

# 当前工程、动作记录目录和已有骨架计算工具。
PROJECT = Path(__file__).resolve().parents[3]
OUTPUT = Path(__file__).resolve().parent
HELPER_SPEC = importlib.util.spec_from_file_location('walk_helpers', OUTPUT.parent/'走路循环/制作流程.py')
HELPERS = importlib.util.module_from_spec(HELPER_SPEC)
HELPER_SPEC.loader.exec_module(HELPERS)
# 起始拄杖停顿、施法过渡和结尾保持的总时长。
DURATION = 2.40
KEY_TIMES = [0,0.20,0.35,0.43,0.51,0.59,0.67,0.75,0.83,0.91,0.99,1.07,1.15,1.23,1.31,1.39,1.47,1.60,2.00,2.40]


def progress(time, start, end):
    """生成阶段内平顺的动作进度。"""
    return HELPERS.ease((time-start)/(end-start))


def axis_rotation(source, target):
    """求两个单位方向之间的最短旋转，用于保持固定握柄轴对准目标。"""
    dot = sum(a*b for a,b in zip(source,target))
    cross = [source[1]*target[2]-source[2]*target[1],source[2]*target[0]-source[0]*target[2],source[0]*target[1]-source[1]*target[0]]
    values = [*cross,1+dot]
    norm = math.sqrt(sum(value*value for value in values))
    if norm<0.000001:
        raise ValueError('握柄方向发生反向奇异，需要调整前臂旋转。')
    return tuple(value/norm for value in values)


def make_pose(bones, time, grip_axis=None):
    """组合小幅右脚前移、左偏躯干和右臂前指，并解算足部与握杖方向。"""
    lookup = {bone['id']:bone for bone in bones}
    angles = {bone['id']:[0.0,0.0,0.0] for bone in bones}
    body = progress(time,0.40,1.35)
    step = progress(time,0.40,0.90)
    arm = progress(time,0.35,1.45)
    root = [round(0.03*body,2),round(-0.02-0.02*body,2),round(0.05*body,2)]
    angles.update({
        'pelvis':[0,0,round(-body,2)],
        'spine_lower':[0,0,round(-3*body,2)],
        'spine_upper':[0,0,round(-2*body,2)],
        'chest':[1,0,round(-2*body,2)],
        'neck':[0,0,round(2*body,2)],
        'head':[-1,0,round(2*body,2)],
        'clavicle_l':[0,0,-3], 'clavicle_r':[0,0,3],
        'upper_arm_l':[0,round(5*body,2),round(-82+3*body,2)],
        'forearm_l':[0,round(-12-8*body,2),0], 'hand_l':[0,0,-3],
        'upper_arm_r':[0,round(55*arm,2),round(75+3*arm,2)],
        'forearm_r':[round(75-160*arm,2),round(75+10*arm,2),0],
        # 初始握杖采用适度腕部侧弯，为随后转杖保留活动范围。
        'hand_r':[0,0,-45 if grip_axis is None else 0],
    })
    for side in ['l','r']:
        x = 0.13 if side=='l' else -0.13
        y = 0.055 if side=='l' else 0.055+0.025*math.sin(math.pi*step)**2
        z = 0.05 if side=='l' else 0.05+0.18*step
        pitch = 0 if side=='l' else -3*math.sin(math.pi*step)
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
        angles[f'foot_{side}'] = HELPERS.euler(HELPERS.mul(HELPERS.inverse(leg_rotation),HELPERS.quaternion([pitch,0,0])))
    if grip_axis is not None:
        state = HELPERS.fk(bones,angles,root)
        neutral_rotation = state['hand_r'][1]
        tilt = math.pi*0.5*arm
        target_axis = (0,math.cos(tilt),math.sin(tilt))
        # 优先用前臂旋前旋后对齐握柄，减少手腕侧弯，避免过渡中超过关节限制。
        untwisted = HELPERS.mul(neutral_rotation,HELPERS.quaternion([-angles['forearm_r'][0],0,0]))
        local_target = HELPERS.rotate(HELPERS.inverse(untwisted),target_axis)
        twist = math.degrees(math.atan2(local_target[2],local_target[1])-math.atan2(grip_axis[2],grip_axis[1]))
        twist = (twist+180)%360-180
        angles['forearm_r'][0] = round(max(-85,min(85,twist)),2)
        neutral_rotation = HELPERS.mul(untwisted,HELPERS.quaternion([angles['forearm_r'][0],0,0]))
        current_axis = HELPERS.rotate(neutral_rotation,grip_axis)
        desired = HELPERS.mul(axis_rotation(current_axis,target_axis),neutral_rotation)
        angles['hand_r'] = HELPERS.euler(HELPERS.mul(HELPERS.inverse(neutral_rotation),desired))
    for bone in bones:
        for axis,value in enumerate(angles[bone['id']]):
            if not bone['limits']['minimum_deg'][axis]-0.001 <= value <= bone['limits']['maximum_deg'][axis]+0.001:
                raise ValueError(f'关节超限：{bone["id"]}，时间 {time}，{angles[bone["id"]]}')
    return {'rotations_deg':angles,'root_m':root}


async def run():
    """经 MCP 保存动作，检查姿势和握杖方向，播放后停在最终施法姿态。"""
    parameters = StdioServerParameters(command=sys.executable,args=[str(PROJECT/'mcp_service/server.py')])
    async with stdio_client(parameters) as streams:
        async with ClientSession(*streams) as session:
            await session.initialize()

            async def call(name, params=None):
                """执行工具并保存结构化记录，错误时停止后续操作。"""
                result = await session.call_tool(name,params or {})
                data = result.structured_content
                with (OUTPUT/'MCP操作记录.jsonl').open('a',encoding='utf-8') as log:
                    log.write(json.dumps({'tool':name,'arguments':params or {},'result':data},ensure_ascii=False)+'\n')
                if result.is_error or not data or not data.get('ok'):
                    raise RuntimeError(json.dumps(data,ensure_ascii=False))
                return data,result

            async def write(name, params):
                """使用当前文档修订和唯一请求编号提交修改。"""
                document,_ = await call('get_document')
                return await call(name,{'document_id':document['document_id'],'expected_revision':document['revision'],'request_id':uuid.uuid4().hex,**params})

            original,_ = await call('get_document')
            if original['draft_dirty']:
                raise RuntimeError('当前存在未保存的手动姿势，需要先保留该姿势。')
            rig,_ = await call('get_rig',{'rig_id':'standard_humanoid_v1'})
            bones = rig['rig']['bones']
            (OUTPUT/'骨骼数据.json').write_text(json.dumps(rig,ensure_ascii=False,indent=2),encoding='utf-8')
            initial = make_pose(bones,0)
            initial_hand = HELPERS.fk(bones,initial['rotations_deg'],initial['root_m'])['hand_r']
            grip_axis = HELPERS.rotate(HELPERS.inverse(initial_hand[1]),(0,1,0))
            grip = {'bone_id':'hand_r','staff_axis_in_hand':grip_axis,'below_grip_length_m':round(initial_hand[0][1],2),'above_grip_length_m':0.60,'note':'挂点参考数据，不代表当前视口已添加法杖模型；初始杖底位于地面，最终杖轴朝向骨架正前方。'}
            (OUTPUT/'握杖挂点参考.json').write_text(json.dumps(grip,ensure_ascii=False,indent=2),encoding='utf-8')
            poses = [make_pose(bones,time,grip_axis) for time in KEY_TIMES]
            state_file = OUTPUT/'动画标识.json'
            if state_file.exists():
                target = json.loads(state_file.read_text(encoding='utf-8'))
            else:
                created,_ = await write('create_clip',{'rig_id':'standard_humanoid_v1','name':'拄杖站立转前指施法','duration_seconds':DURATION,'fps':60,'loop':False,'interpolation':'linear'})
                target = {'rig_id':created['clip']['rig_id'],'clip_id':created['clip']['clip_id']}
                state_file.write_text(json.dumps(target,ensure_ascii=False,indent=2),encoding='utf-8')
            commands = [{'op':'upsert_keyframe','time_seconds':time,**pose} for time,pose in zip(KEY_TIMES,poses)]
            edited,_ = await write('apply_edit_batch',{**target,'commands':commands})
            (OUTPUT/'关键姿势规划.json').write_text(json.dumps(commands,ensure_ascii=False,indent=2),encoding='utf-8')
            print('已保存动画',json.dumps(edited['clip'],ensure_ascii=False),flush=True)
            validation,_ = await call('validate_clip',target)
            samples = []
            for time in [0,0.20,0.35,0.39,0.47,0.55,0.63,0.71,0.79,0.87,0.95,1.03,1.11,1.19,1.27,1.35,1.43,1.60,2.40]:
                sample,_ = await call('evaluate_pose',{**target,'time_seconds':time,'bone_ids':['pelvis','chest','head','hand_l','hand_r','shin_l','shin_r','foot_l','toe_l','foot_r','toe_r']})
                hand = next(joint for joint in sample['joints'] if joint['bone_id']=='hand_r')
                staff_axis = HELPERS.rotate(hand['rotation_xyzw'],grip_axis)
                sample['staff_reference'] = {'axis':staff_axis,'bottom_m':[position-direction*grip['below_grip_length_m'] for position,direction in zip(hand['position_m'],staff_axis)]}
                samples.append(sample)
            (OUTPUT/'实际姿势采样.json').write_text(json.dumps(samples,ensure_ascii=False,indent=2),encoding='utf-8')
            last = {joint['bone_id']:joint for joint in samples[-1]['joints']}
            minimum_foot_y = min(joint['position_m'][1] for sample in samples for joint in sample['joints'] if joint['bone_id'].startswith(('foot_','toe_')))
            await call('seek_animation',{**target,'time_seconds':0.0})
            await call('set_view',{'preset':'custom','yaw_deg':-35,'pitch_deg':5,'target_m':[0,0.95,0.10],'distance_m':3.4})
            started,_ = await call('set_playback',{**target,'playing':True})
            await asyncio.sleep(0.3)
            playing,_ = await call('get_document')
            if not playing['playing'] or playing['current_tick']==started['current_tick']:
                raise RuntimeError('动画播放没有推进。')
            captures = [('正面_拄杖站立',0,'front'),('右侧_拄杖站立',0,'right'),('右侧_抬杖过渡',0.90,'right'),('右侧_前指施法',1.60,'right'),('正面_左偏施法',1.60,'front'),('斜前方_拄杖站立',0,'custom'),('斜前方_前指施法',1.60,'custom')]
            frames = [{'time_seconds':time,'view':{'preset':preset,'pitch_deg':5,'target_m':[0,0.95,0.10],'distance_m':3.4,**({'yaw_deg':-35} if preset=='custom' else {})}} for name,time,preset in captures]
            captured,media = await call('render_preview',{**target,'width':768,'height':768,'frames':frames})
            filenames = []
            for (name,time,preset),block in zip(captures,media.content[1:]):
                filename = name+'.png'
                (OUTPUT/filename).write_bytes(base64.b64decode(block.data))
                filenames.append(filename)
            await asyncio.sleep(max(0,(DURATION-playing['time_seconds'])/max(playing['playback_speed'],0.1))+0.1)
            final,_ = await call('get_document')
            report = {'clip':edited['clip'],'joint_limits_valid':validation['valid'],'minimum_foot_joint_y_m':minimum_foot_y,'right_foot_forward_distance_m':last['foot_r']['position_m'][2]-last['foot_l']['position_m'][2],'chest_left_offset_from_pelvis_m':last['chest']['position_m'][0]-last['pelvis']['position_m'][0],'initial_staff_axis':samples[0]['staff_reference']['axis'],'final_staff_axis':samples[-1]['staff_reference']['axis'],'minimum_reference_staff_bottom_y_m':min(sample['staff_reference']['bottom_m'][1] for sample in samples),'playback_verified':True,'final_playing':final['playing'],'final_time_seconds':final['time_seconds'],'original_clips_preserved':all(any(clip['clip_id']==old['clip_id'] and clip['clip_revision']==old['clip_revision'] for clip in final['clips']) for old in original['clips'] if old['clip_id']!=target['clip_id']),'images':filenames}
            (OUTPUT/'检查结果.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
            print(json.dumps(report,ensure_ascii=False),flush=True)


if __name__ == '__main__':
    asyncio.run(run())

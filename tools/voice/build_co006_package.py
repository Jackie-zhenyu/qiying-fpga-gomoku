"""Build a vendor-format offline profile without modifying original materials."""
from pathlib import Path
from copy import deepcopy
import argparse
import csv
import hashlib
import json
import re
import xml.etree.ElementTree as ET
import zipfile

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parents[1]
parser = argparse.ArgumentParser(description='Create an offline CO006 workbook from the vendor Chinese V3 template. No serial, flashing, or network access.')
parser.add_argument('template', type=Path, help='Vendor-provided 命令词播报词协议列表V3_中文.xlsx')
parser.add_argument('--output', type=Path, default=SCRIPT_DIR / 'generated', help='New output directory (must not exist)')
args = parser.parse_args()
SOURCE = args.template.resolve()
HERE = args.output.resolve()
SOURCE_SHA256 = '307720a2ea1f3cbd2269f5b54057e6bb8ba1da4ee9f88dda7159b9f40f31f542'
NS = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
Q = lambda name: f'{{{NS}}}{name}'
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()

COMMANDS = [
 ('开始对局', '选中对弈入口或打开新局确认，仍由实体确认键继续'),
 ('请求提示', '仅在当前真实局面允许时请求教学'),
 ('重听提示', '仅重听当前仍有效提示'),
 ('暂停对局', '目标状态为暂停，重复指令不翻转'),
 ('继续对局', '目标状态为继续，仍需视觉复核'),
 ('现在谁下', '从当前状态播报轮次或正在处理'),
 ('查看历史', '选中只读历史入口，仍由实体确认键进入'),
 ('返回主页', '返回主页并保留当前正式棋局'),
]
PHRASES = [
 '对弈入口已选，请按确认键继续。',
 '历史入口已选，请按确认键查看。',
 '已暂停对局。',
 '已继续对局，请保持棋盘不动。',
 '轮到黑棋。',
 '轮到白棋。',
 '请按屏幕标记放置电脑棋子，等待摄像头确认。',
 '黑棋落子已由摄像头确认。',
 '白棋落子已由摄像头确认。',
 '请查看屏幕上的一步取胜点。',
 '请查看屏幕上的直接威胁。',
 '当前局面没有可用教学任务。',
 '当前状态不能请求教学。',
 '回答正确，落子已记入棋谱。',
 '落子已记入棋谱，请查看教学分析。',
 '棋盘状态异常，请检查画面。',
 '相机尚未就绪，请稍候。',
 '已回到主页，当前棋局保留。',
 '黑棋获胜。',
 '白棋获胜。',
 '本局和棋。',
 '当前正在处理，请稍候。',
 '请先完成棋盘设置和视觉标定。',
 '当前没有可重听的有效提示。',
 '存在多个威胁，请查看屏幕分析。',
]
assert len(COMMANDS) == 8 and len(PHRASES) == 25
assert sha(SOURCE) == SOURCE_SHA256, 'The supplied template does not match the supported vendor Chinese V3 workbook'
HERE.mkdir(parents=True, exist_ok=False)

records = []
for index, (word, meaning) in enumerate(COMMANDS, 1):
    wire_id = 0xc0 + index
    records.append(dict(logical=index, kind='command', word=word, module_id=wire_id,
                        module_id_hex=f'{wire_id:02X}', type=0, frame=f'AA 55 00 {wire_id:02X} FB',
                        reply='收到请求', mode='被', meaning=meaning))
for index, word in enumerate(PHRASES):
    wire_id = 0xd0 + index
    records.append(dict(logical=wire_id, kind='phrase', word=word, module_id=wire_id,
                        module_id_hex=f'{wire_id:02X}', type=255, frame=f'AA 55 FF {wire_id:02X} FB',
                        reply=word, mode='被', meaning='由实际状态或已核验事件触发，逻辑ID即线上ID'))

with zipfile.ZipFile(SOURCE) as original:
    sheet_bytes = original.read('xl/worksheets/sheet1.xml')
    sheet = ET.fromstring(sheet_bytes)
    shared = ET.fromstring(original.read('xl/sharedStrings.xml'))
    strings = [''.join(item.itertext()) for item in shared]

    def values(row):
        out = {}
        for cell in row:
            col = re.sub('[0-9]', '', cell.get('r'))
            if cell.get('t') == 's':
                value = strings[int(cell.find(Q('v')).text)]
            elif cell.get('t') == 'inlineStr':
                value = ''.join(cell.find(Q('is')).itertext())
            else:
                node = cell.find(Q('v'))
                value = None if node is None else node.text
            out[col] = value
        return out

    data = sheet.find(Q('sheetData'))
    old_rows = {int(row.get('r')): row for row in data}
    original_functions = [values(old_rows[n]) for n in range(2, 12)]
    for row in list(data):
        if int(row.get('r')) > 11:
            data.remove(row)
    # Existing source styles are reused; only values and applicable row bounds change.
    styles = ['30', '31', '31', '31', '31', '31', '31']
    for row_number, record in enumerate(records, 12):
        row = ET.SubElement(data, Q('row'), {'r': str(row_number), 'spans': '1:7'})
        row_values = [row_number - 1, record['word'], '命令词' if record['kind'] == 'command' else '播报语',
                      record['reply'], record['mode'], record['frame'], record['frame']]
        for col, style, value in zip('ABCDEFG', styles, row_values):
            cell = ET.SubElement(row, Q('c'), {'r': f'{col}{row_number}', 's': style})
            if isinstance(value, int):
                ET.SubElement(cell, Q('v')).text = str(value)
            else:
                cell.set('t', 'inlineStr')
                ET.SubElement(ET.SubElement(cell, Q('is')), Q('t')).text = value
    last_row = 11 + len(records)
    dimension = sheet.find(Q('dimension'))
    if dimension is not None:
        dimension.set('ref', f'A1:J{last_row}')
    for validation in sheet.findall(f'{Q("dataValidations")}/{Q("dataValidation")}'):
        col = validation.get('sqref')[0]
        validation.set('sqref', f'{col}2:{col}{last_row}')
    for view in sheet.findall(f'{Q("sheetViews")}/{Q("sheetView")}'):
        view.set('topLeftCell', 'A1')
        for selection in view.findall(Q('selection')):
            selection.set('activeCell', 'A1');selection.set('sqref', 'A1')
    ET.register_namespace('', NS)
    ET.register_namespace('r', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')
    output = HERE / 'qiying_voice_profile_CO006.xlsx'
    new_bytes = ET.tostring(sheet, encoding='utf-8', xml_declaration=True)
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as updated:
        for info in original.infolist():
            updated.writestr(deepcopy(info), new_bytes if info.filename == 'xl/worksheets/sheet1.xml' else original.read(info.filename))
    # Reopen the actual output, compare all protected contents and every new value.
    with zipfile.ZipFile(output) as updated:
        assert updated.testzip() is None
        for name in updated.namelist():
            if name.endswith(('.xml', '.rels')):
                ET.fromstring(updated.read(name))
        changed = [name for name in original.namelist() if original.read(name) != updated.read(name)]
        assert changed == ['xl/worksheets/sheet1.xml']
        loaded = ET.fromstring(updated.read('xl/worksheets/sheet1.xml')).find(Q('sheetData'))
        loaded_rows = {int(row.get('r')): row for row in loaded}
        assert [values(loaded_rows[n]) for n in range(2, 12)] == original_functions
        assert len(loaded_rows) == 44
        for row_number, record in enumerate(records, 12):
            actual = values(loaded_rows[row_number])
            assert actual['B'] == record['word'] and actual['D'] == record['reply']
            assert actual['E'] == '被' and actual['F'] == actual['G'] == record['frame']
        assert len({values(loaded_rows[n])['A'] for n in range(2, 45)}) == 43

csv_path = HERE / 'word_map_CO006.csv'
with csv_path.open('w', encoding='utf-8-sig', newline='') as handle:
    writer = csv.DictWriter(handle, fieldnames=records[0].keys())
    writer.writeheader();writer.writerows(records)

profile = dict(schema_version=2, profile_name='peripherals006_C1_C8_D0_E8',
               status='offline_profile_not_module_firmware',
               voice=dict(enabled=False, firmware_label='pending_custom_CI1302_build', firmware_sha256='',
                          uart=dict(baud=115200, data_bits=8, parity='none', stop_bits=1),
                          frame_timeout_us=20000, repeat_gap_us=300000, speech_gap_us=12000000,
                          playback_complete_ack=False, phrase_id_is_wire_id=True,
                          commands=records[:8], phrases=records[8:]))
profile_path = HERE / 'profile_CO006_DISABLED.json'
profile_path.write_text(json.dumps(profile, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
rtl = ROOT / 'fpga/qy_peripheral_voice.v'
rtl_text = rtl.read_text(encoding='utf-8')
for token in ["rx_id>=8'hc1&&rx_id<=8'hc8", "phrase_id>=8'hd0&&phrase_id<=8'he8", 'SPEECH_GAP_US=12000000']:
    assert token in rtl_text
factory = json.loads((SCRIPT_DIR/'documented_wire_ids.json').read_text(encoding='utf-8'))
assert not {r['module_id_hex'] for r in records[:8]} & set(factory['00']['ids'])
assert not {r['module_id_hex'] for r in records[8:]} & set(factory['FF']['ids'])
metadata = dict(schema_version=2, status='offline_profile_verified_not_firmware', firmware_generated=False,
                firmware_flashed=False, hardware_tested=False, runtime_enable_default=False,
                source_template=SOURCE.name, source_template_sha256=SOURCE_SHA256,
                generated_xlsx=output.name, generated_xlsx_sha256=sha(output),
                template_first_10_function_rows_preserved=True, template_other_archive_parts_byte_identical=True,
                command_count=8, phrase_count=25, commands_are_passive_to_avoid_premature_success_audio=True,
                command_wire_range='C1..C8', phrase_wire_range='D0..E8', phrase_id_is_wire_id=True,
                speech_gap_us=12000000, measured_audio_duration_available=False, playback_complete_ack=False,
                voice_rtl_sha256=sha(rtl), csv_sha256=sha(csv_path), profile_sha256=sha(profile_path),
                source_factory_type00_maximum='5E', scope_of_noncollision='Supplied Chinese V3 table, not live firmware attestation',
                supersedes='qiying_voice_profile_DRAFT.xlsx / word_map_DRAFT.csv / profile_DRAFT_DISABLED.json (6 commands + 15 phrases)',
                verification=['Output archive re-opened; all XML parses; first 10 function entries unchanged',
                              'All other vendor XLSX archive parts byte-identical including instructions, styles and shared strings',
                              'Exactly 8 commands and 25 phrases, unique labels, mode 被, matching send/receive frames',
                              'All 33 protocol entries matched to leaf RTL accepted ranges; this builder does not run RTL tests'],
                remaining=['Import XLSX into vendor platform and confirm passive commands still send UART events',
                           'Generate CI1302 Chinese 2MB firmware and record actual bin SHA256',
                           'Measure all 25 audio durations; retain or increase conservative 12-second spacing as required',
                           'Confirm module UART electrical levels and correct 1.8V level conversion',
                           'Flash and physically validate later when both modules are available'])
old = HERE / 'OFFLINE_PACKAGE.json'
archive = HERE / 'OFFLINE_PACKAGE_DRAFT.json'
if old.exists() and not archive.exists():
    archive.write_bytes(old.read_bytes())
old.write_text(json.dumps(metadata, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
(HERE/'OFFLINE_PACKAGE_CO006.json').write_bytes(old.read_bytes())
print(json.dumps({'status': metadata['status'], 'commands': 8, 'phrases': 25,
                  'xlsx_sha256': sha(output), 'protected_template_parts_unchanged': True}, indent=2))

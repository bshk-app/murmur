"""Pinned detector/dictionary resources. Recognizer weights are downloaded on device."""
import hashlib,json,urllib.request,warnings
from pathlib import Path
import onnx,onnxruntime as ort
from onnxconverter_common import float16
ROOT=Path(__file__).resolve().parents[1];cache=ROOT/'.build/models';cache.mkdir(parents=True,exist_ok=True);out=ROOT/'Sources/MurmurOCR/Resources'
base='https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.9.2/onnx/'
models={
 'PP-OCRv6_det_tiny.onnx':('PP-OCRv6/det/','f42c0fbd294d95eac1a550e131b277dac97462c8025fa4b6c3cec1b7894bd3d5'),
 'PP-OCRv6_rec_tiny.onnx':('PP-OCRv6/rec/','e16e242de5937ad92609223f19bc2aff3727ee40b095f996907c24749bad251b'),
 'cyrillic_PP-OCRv5_rec_mobile.onnx':('PP-OCRv5/rec/','90f761b4bfcce0c8c561c0cb5c887b0971d3ec01c32164bdf7374a35b0982711'),
 'el_PP-OCRv5_rec_mobile.onnx':('PP-OCRv5/rec/','b4368bccd557123c702b7549fee6cd1e94b581337d1c9b65310f109131542b7f'),
 'arabic_PP-OCRv5_rec_mobile.onnx':('PP-OCRv5/rec/','c1192e632d0baa9146ae5b756a0e635e3dc63c1733737ebfd1629e87144e9295')}
for name,(folder,digest) in models.items():
 p=cache/name
 if not p.exists():urllib.request.urlretrieve(base+folder+name,p)
 assert hashlib.sha256(p.read_bytes()).hexdigest()==digest,name
for label,(h,w) in {'landscape':(768,1024),'portrait':(1024,768)}.items():
 m=onnx.load(cache/'PP-OCRv6_det_tiny.onnx');s=m.graph.input[0].type.tensor_type.shape;s.ClearField('dim')
 for x in [1,3,h,w]:s.dim.add().dim_value=x
 del m.graph.value_info[:];m=onnx.shape_inference.infer_shapes(m)
 with warnings.catch_warnings():warnings.simplefilter('ignore',UserWarning);m=float16.convert_float_to_float16(m,keep_io_types=True)
 producers={o:n for n in m.graph.node for o in n.output};drop=set();stale=set()
 for n in m.graph.node:
  if n.op_type!='Resize':continue
  before=producers[n.input[0]];after=next(a for a in m.graph.node if a.op_type=='Cast' and list(a.input)==[n.output[0]])
  assert before.op_type=='Cast';stale.update([before.output[0],n.output[0]]);n.input[0]=before.input[0];n.output[0]=after.output[0];drop.update([before.name,after.name])
 nodes=[n for n in m.graph.node if n.name not in drop];del m.graph.node[:];m.graph.node.extend(nodes)
 info=[v for v in m.graph.value_info if v.name not in stale];del m.graph.value_info[:];m.graph.value_info.extend(info);onnx.checker.check_model(m);onnx.save(m,out/f'detector-{label}.onnx')
chars={}
for name in models:
 if '_rec_' not in name:continue
 opt=ort.SessionOptions();opt.intra_op_num_threads=2
 s=ort.InferenceSession(str(cache/name),opt,providers=['CPUExecutionProvider']);chars[name]=['blank']+s.get_modelmeta().custom_metadata_map['character'].splitlines()+[' ']
(out/'dictionaries.json').write_text(json.dumps(chars,ensure_ascii=False))
(out/'model-provenance.json').write_text(json.dumps({name:{'url':base+folder+name,'sha256':sha} for name,(folder,sha) in models.items()},indent=2))

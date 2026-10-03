"""Export existing v6-small/v5-mobile weights for a controlled simulator comparison.

Same input shapes and FP16 Resize treatment as the bundled v6-tiny detector.
Does not replace any shipped model resource.
"""
import hashlib
import json
import sys
import warnings
from pathlib import Path

import onnx
from onnxconverter_common import float16

source, output = map(Path, sys.argv[1:3])
variant = sys.argv[3] if len(sys.argv) > 3 else "v6-small"
assert variant in {"v6-small", "v5-mobile"}
output.mkdir(parents=True, exist_ok=True)
records = {"source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(), "variants": {}}
expected = {
    "v6-small": "090f04abcd9d9a7498bc4ebf677e4cb9bdce1fe4197ddb7e529f1ef44e1ff94f",
    "v5-mobile": "4d97c44a20d30a81aad087d6a396b08f786c4635742afc391f6621f5c6ae78ae",
}
assert records["source_sha256"] == expected[variant], "Unexpected source model"
for label, (height, width) in {"landscape": (768, 1024), "portrait": (1024, 768)}.items():
    model = onnx.load(source)
    shape = model.graph.input[0].type.tensor_type.shape
    shape.ClearField("dim")
    for value in [1, 3, height, width]:
        shape.dim.add().dim_value = value
    del model.graph.value_info[:]
    model = onnx.shape_inference.infer_shapes(model)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        model = float16.convert_float_to_float16(model, keep_io_types=True)
    producers = {out: node for node in model.graph.node for out in node.output}
    drop, stale = set(), set()
    for node in model.graph.node:
        if node.op_type != "Resize":
            continue
        before = producers[node.input[0]]
        after = next(n for n in model.graph.node if n.op_type == "Cast" and list(n.input) == [node.output[0]])
        assert before.op_type == "Cast"
        stale.update([before.output[0], node.output[0]])
        node.input[0], node.output[0] = before.input[0], after.output[0]
        drop.update([before.name, after.name])
    nodes = [node for node in model.graph.node if node.name not in drop]
    del model.graph.node[:]
    model.graph.node.extend(nodes)
    info = [value for value in model.graph.value_info if value.name not in stale]
    del model.graph.value_info[:]
    model.graph.value_info.extend(info)
    onnx.checker.check_model(model)
    path = output / f"{variant}-{label}.onnx"
    onnx.save(model, path)
    records["variants"][label] = {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "bytes": path.stat().st_size}
(output / f"{variant}-provenance.json").write_text(json.dumps(records, indent=2))
print(json.dumps(records, indent=2))

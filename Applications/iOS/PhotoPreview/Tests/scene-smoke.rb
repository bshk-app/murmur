# Runs the real installed preview on an arm64 simulator; models must be prepared first.
require 'json'
require 'fileutils'
require 'open3'
require 'timeout'

device = ENV.fetch('SIMULATOR_UDID', 'C74F7467-8F39-4D41-9F12-E4E6FDAEC428')
fixture, source, target, expected, output = ARGV
abort 'Usage: ruby scene-smoke.rb IMAGE SOURCE TARGET EXPECTED_TEXT OUTPUT_JSON' unless output
bundle = 'app.bshk.murmur.photo-preview'
container, status = Open3.capture2('xcrun', 'simctl', 'get_app_container', device, bundle, 'data')
abort 'Preview is not installed' unless status.success?
documents = File.join(container.strip, 'Documents')
result = File.join(documents, 'photo-probe-result.json')
system('xcrun', 'simctl', 'terminate', device, bundle, out: File::NULL, err: File::NULL)
FileUtils.rm_f(result)
FileUtils.cp(fixture, File.join(documents, 'photo-probe.jpg'))
env = { 'SIMCTL_CHILD_PHOTO_PROBE_SOURCE' => source, 'SIMCTL_CHILD_PHOTO_PROBE_TARGET' => target }
%w[PHOTO_PROBE_MAX_PIXELS OCR_PROBE_UNCLIP OCR_PROBE_DILATE OCR_PROBE_REDETECT OCR_PROBE_DETECTOR].each { |key| env["SIMCTL_CHILD_#{key}"] = ENV[key] || '' }
abort 'Launch failed' unless system(env, 'xcrun', 'simctl', 'launch', device, bundle, '--photo-translation-probe')
Timeout.timeout(120) { sleep 0.2 until File.exist?(result) }
data = JSON.parse(File.read(result))
FileUtils.cp(result, output)
texts = data.fetch('blocks').map { |block| block.fetch('source') }
normalize = ->(text) { text.upcase.gsub(/[^\p{L}\p{N}]/, '') }
# Allow adjacent regions without ignoring spurious letters inside a region.
matched = texts.each_index.any? do |start|
  (start...texts.length).any? { |finish| normalize.call(texts[start..finish].join(' ')) == normalize.call(expected) }
end
passed = data['didOCR'] && data['error'] == '' && matched
puts JSON.generate({passed: passed, texts: texts, seconds: data['seconds'], error: data['error']})
exit(passed ? 0 : 1)

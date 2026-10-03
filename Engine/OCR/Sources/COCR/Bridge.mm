// Experimental full native OCR pipeline. DB/CTC processing follows PaddleOCR/RapidOCR.
// See THIRD_PARTY.md for attribution. This target does not use ML Kit.
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#include <sys/utsname.h>
#include <sys/resource.h>
#include <mach/mach.h>
#import <onnxruntime_objc/onnxruntime.h>
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/highgui.hpp>
#include "clipper.hpp"
#import "COCR.h"
#include <algorithm>
#include <numeric>
#include <array>
#include <cmath>
using Quad = std::array<cv::Point2f, 4>;
static double clockNow() { return NSProcessInfo.processInfo.systemUptime; }
static ORTSessionOptions *coreMLSessionOptions(NSString *output, BOOL profile) {
  NSError *e = nil;
  ORTSessionOptions *o = [[ORTSessionOptions alloc] initWithError:&e];
  if (e)
    @throw [NSException exceptionWithName:@"ORT" reason:e.localizedDescription userInfo:nil];
  [o setIntraOpNumThreads:2 error:&e];
  [o addConfigEntryWithKey:@"session.enable_cpu_mem_arena" value:@"0" error:&e];
  [o appendCoreMLExecutionProviderWithOptionsV2:@{
    @"ModelFormat" : @"MLProgram",
    @"MLComputeUnits" : @"CPUAndNeuralEngine",
    @"RequireStaticInputShapes" : @"1",
    @"ProfileComputePlan" : profile ? @"1" : @"0",
    @"ModelCacheDirectory" : [output stringByAppendingPathComponent:@"coreml-cache"]
  }
                                          error:&e];
  if (e)
    @throw [NSException exceptionWithName:@"ORT" reason:e.localizedDescription userInfo:nil];
  return o;
}
static void fail(NSError *e) {
  if (e)
    @throw [NSException exceptionWithName:@"ORT" reason:e.localizedDescription userInfo:nil];
}
static Quad ordered(cv::RotatedRect rect) {
  cv::Point2f p[4];
  rect.points(p);
  std::sort(p, p + 4, [](auto a, auto b) { return a.x < b.x; });
  if (p[0].y > p[1].y)
    std::swap(p[0], p[1]);
  if (p[2].y > p[3].y)
    std::swap(p[2], p[3]);
  return {p[0], p[2], p[3], p[1]};
}
static NSMutableData *tensor(const std::vector<cv::Mat> &images, int h, int w, bool rec) {
  NSMutableData *d = [NSMutableData dataWithLength:images.size() * 3 * h * w * sizeof(float)];
  float *dst = (float *)d.mutableBytes;
  for (size_t n = 0; n < images.size(); n++) {
    int rw = rec ? std::min(w, (int)ceil(h * (double)images[n].cols / images[n].rows)) : w;
    cv::Mat resized;
    cv::resize(images[n], resized, {rw, h});
    for (int y = 0; y < h; y++)
      for (int x = 0; x < rw; x++)
        for (int c = 0; c < 3; c++)
          dst[((n * 3 + c) * h + y) * w + x] = (resized.at<cv::Vec3b>(y, x)[c] / 255.0 - 0.5) / 0.5;
  }
  return d;
}
static ORTValue *run(ORTSession *s, NSMutableData *d, NSArray *shape) {
  NSError *e = nil;
  ORTValue *input = [[ORTValue alloc] initWithTensorData:d
                                             elementType:ORTTensorElementDataTypeFloat
                                                   shape:shape
                                                   error:&e];
  fail(e);
  NSString *iname = [s inputNamesWithError:&e].firstObject;
  fail(e);
  NSString *oname = [s outputNamesWithError:&e].firstObject;
  fail(e);
  NSDictionary *result = [s runWithInputs:@{iname : input}
                              outputNames:[NSSet setWithObject:oname]
                               runOptions:nil
                                    error:&e];
  fail(e);
  if (!result)
    @throw [NSException exceptionWithName:@"ORT" reason:@"empty output" userInfo:nil];
  return result[oname];
}
static std::vector<Quad> boxes(ORTValue *value, int width, int height) {
  NSError *e = nil;
  NSArray *shape = [value tensorTypeAndShapeInfoWithError:&e].shape;
  fail(e);
  if (shape.count != 4)
    @throw [NSException exceptionWithName:@"shape"
                                   reason:@"detector output must be NCHW"
                                 userInfo:nil];
  int h = [shape[2] intValue], w = [shape[3] intValue];
  NSMutableData *data = [value tensorDataWithError:&e];
  fail(e);
  cv::Mat pred(h, w, CV_32F, data.mutableBytes), mask;
  cv::compare(pred, 0.3, mask, cv::CMP_GT);
  bool dilate = true;
#if TARGET_OS_SIMULATOR
  if ([NSProcessInfo.processInfo.arguments containsObject:@"--photo-translation-probe"] &&
      [NSProcessInfo.processInfo.environment[@"OCR_PROBE_DILATE"] isEqualToString:@"0"]) dilate = false;
#endif
  if (dilate) cv::dilate(mask, mask, cv::Mat::ones(2, 2, CV_8U));
  std::vector<std::vector<cv::Point>> contours;
  cv::findContours(mask, contours, cv::RETR_LIST, cv::CHAIN_APPROX_SIMPLE);
  std::vector<Quad> result;
  for (size_t i = 0; i < std::min(contours.size(), size_t(1000)); i++) {
    auto rect = cv::minAreaRect(contours[i]);
    if (std::min(rect.size.width, rect.size.height) < 3)
      continue;
    Quad q = ordered(rect);
    float xmin = q[0].x, xmax = xmin, ymin = q[0].y, ymax = ymin;
    for (auto p : q) {
      xmin = std::min(xmin, p.x);
      xmax = std::max(xmax, p.x);
      ymin = std::min(ymin, p.y);
      ymax = std::max(ymax, p.y);
    }
    int x0 = std::clamp((int)floor(xmin), 0, w - 1), x1 = std::clamp((int)ceil(xmax), 0, w - 1),
        y0 = std::clamp((int)floor(ymin), 0, h - 1), y1 = std::clamp((int)ceil(ymax), 0, h - 1);
    cv::Mat scoremask = cv::Mat::zeros(y1 - y0 + 1, x1 - x0 + 1, CV_8U);
    std::vector<cv::Point> poly;
    for (auto p : q)
      poly.push_back({int(p.x - x0), int(p.y - y0)});
    cv::fillPoly(scoremask, std::vector<std::vector<cv::Point>>{poly}, 1);
    if (cv::mean(pred(cv::Rect(x0, y0, x1 - x0 + 1, y1 - y0 + 1)), scoremask)[0] < 0.5)
      continue;
    std::vector<cv::Point2f> points(q.begin(), q.end());
    double perimeter = cv::arcLength(points, true);
    if (perimeter <= 0)
      continue;
    double unclip = 1.6;
#if TARGET_OS_SIMULATOR
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--photo-translation-probe"]) {
      double requested = [NSProcessInfo.processInfo.environment[@"OCR_PROBE_UNCLIP"] doubleValue];
      if (requested >= 1.0 && requested <= 2.0) unclip = requested;
    }
#endif
    double distance = cv::contourArea(points) * unclip / perimeter;
    ClipperLib::Path path;
    for (auto p : q)
      path.push_back(ClipperLib::IntPoint((long long)p.x, (long long)p.y));
    ClipperLib::ClipperOffset offset;
    offset.AddPath(path, ClipperLib::jtRound, ClipperLib::etClosedPolygon);
    ClipperLib::Paths expanded;
    offset.Execute(expanded, distance);
    std::vector<cv::Point2f> ep;
    for (auto a : expanded)
      for (auto p : a)
        ep.emplace_back(p.X, p.Y);
    if (ep.empty())
      continue;
    rect = cv::minAreaRect(ep);
    if (std::min(rect.size.width, rect.size.height) < 5)
      continue;
    q = ordered(rect);
    for (auto &p : q) {
      p.x = std::clamp((float)nearbyint(p.x / w * width), 0.f, float(width - 1));
      p.y = std::clamp((float)nearbyint(p.y / h * height), 0.f, float(height - 1));
    }
    if (int(cv::norm(q[0] - q[1])) <= 3 || int(cv::norm(q[0] - q[3])) <= 3)
      continue;
    result.push_back(q);
  }
  std::stable_sort(result.begin(), result.end(),
                   [](const Quad &a, const Quad &b) { return a[0].y < b[0].y; });
  size_t begin = 0;
  while (begin < result.size()) {
    size_t end = begin + 1;
    while (end < result.size() && result[end][0].y - result[end - 1][0].y < 10)
      end++;
    std::stable_sort(result.begin() + begin, result.begin() + end,
                     [](const Quad &a, const Quad &b) { return a[0].x < b[0].x; });
    begin = end;
  }
  return result;
}
static cv::Mat crop(const cv::Mat &img, const Quad &q) {
  int w = int(std::max(cv::norm(q[0] - q[1]), cv::norm(q[2] - q[3]))),
      h = int(std::max(cv::norm(q[0] - q[3]), cv::norm(q[1] - q[2])));
  cv::Point2f dest[4] = {{0, 0}, {float(w), 0}, {float(w), float(h)}, {0, float(h)}};
  cv::Mat M = cv::getPerspectiveTransform(q.data(), dest), out;
  cv::warpPerspective(img, out, M, {w, h}, cv::INTER_CUBIC, cv::BORDER_REPLICATE);
  if (double(h) / w >= 1.5)
    cv::rotate(out, out, cv::ROTATE_90_COUNTERCLOCKWISE);
  return out;
}
#if TARGET_OS_SIMULATOR
// Experimental local detection, enabled only by the explicit simulator probe.
// Use surrounding pixels from the source image rather than resizing an OCR crop.
static std::vector<Quad> redetectRegions(const cv::Mat &img, const std::vector<Quad> &initial,
                                        ORTSession *det, int h, int w) {
  std::vector<Quad> refined;
  for (const auto &q : initial) {
    @autoreleasepool {
      cv::Rect bounds = cv::boundingRect(std::vector<cv::Point2f>(q.begin(), q.end()));
      // Bound work and focus the experiment on small text.
      if (bounds.height > 100 || initial.size() > 30) {
        refined.push_back(q);
        continue;
      }
      int marginX = std::max(16, bounds.height), marginY = std::max(32, bounds.height * 2);
      cv::Rect region(bounds.x - marginX, bounds.y - marginY,
                      bounds.width + 2 * marginX, bounds.height + 2 * marginY);
      region &= cv::Rect(0, 0, img.cols, img.rows);
      double scale = std::min(double(w) / region.width, double(h) / region.height);
      int rw = std::max(1, int(std::round(region.width * scale)));
      int rh = std::max(1, int(std::round(region.height * scale)));
      int left = (w - rw) / 2, top = (h - rh) / 2;
      cv::Mat resized, padded;
      cv::resize(img(region), resized, {rw, rh});
      cv::copyMakeBorder(resized, padded, top, h - rh - top, left, w - rw - left,
                         cv::BORDER_CONSTANT, cv::Scalar(255, 255, 255));
      auto candidates = boxes(run(det, tensor({padded}, h, w, false), @[ @1, @3, @(h), @(w) ]), w, h);
      std::vector<Quad> accepted;
      for (auto candidate : candidates) {
        cv::Point2f center(0, 0);
        for (auto &p : candidate) {
          p.x = std::clamp(float(region.x + (p.x - left) * region.width / rw), 0.f, float(img.cols - 1));
          p.y = std::clamp(float(region.y + (p.y - top) * region.height / rh), 0.f, float(img.rows - 1));
          center += p * 0.25f;
        }
        if (cv::pointPolygonTest(std::vector<cv::Point2f>(q.begin(), q.end()), center, false) >= 0)
          accepted.push_back(candidate);
      }
      if (accepted.empty()) refined.push_back(q);
      else refined.insert(refined.end(), accepted.begin(), accepted.end());
    }
  }
  return refined;
}
#endif
static NSDictionary *recognize(NSString *file, ORTSession *det, ORTSession *rec, NSArray *dict,
                               NSString *trace) {
  double start = clockNow();
  cv::Mat img = cv::imread(file.UTF8String);
  if (img.empty())
    @throw [NSException exceptionWithName:@"image" reason:file userInfo:nil];
  double decoded = clockNow();
  if (img.cols > 4096 || img.rows > 4096)
    @throw [NSException exceptionWithName:@"image"
                                   reason:@"Image must be downsampled before OCR"
                                 userInfo:nil];
  int h = img.rows > img.cols ? 1024 : 768, w = img.rows > img.cols ? 768 : 1024;
  double scale = std::min(double(w) / img.cols, double(h) / img.rows);
  int rw = std::max(1, int(std::round(img.cols * scale))),
      rh = std::max(1, int(std::round(img.rows * scale)));
  int left = (w - rw) / 2, top = (h - rh) / 2;
  cv::Mat resized, padded;
  cv::resize(img, resized, {rw, rh});
  cv::copyMakeBorder(resized, padded, top, h - rh - top, left, w - rw - left, cv::BORDER_CONSTANT,
                     cv::Scalar(255, 255, 255));
  NSMutableData *input = tensor({padded}, h, w, false);
  double prep = clockNow();
  ORTValue *pred = run(det, input, @[ @1, @3, @(h), @(w) ]);
  double inferred = clockNow();
  auto paddedQuads = boxes(pred, w, h);
  std::vector<Quad> quads;
  for (auto q : paddedQuads) {
    float minx = q[0].x, maxx = minx, miny = q[0].y, maxy = miny;
    for (auto p : q) {
      minx = std::min(minx, p.x);
      maxx = std::max(maxx, p.x);
      miny = std::min(miny, p.y);
      maxy = std::max(maxy, p.y);
    }
    if (maxx <= left || minx >= left + rw || maxy <= top || miny >= top + rh)
      continue;
    for (auto &p : q) {
      p.x = std::clamp(float((p.x - left) * img.cols / rw), 0.f, float(img.cols - 1));
      p.y = std::clamp(float((p.y - top) * img.rows / rh), 0.f, float(img.rows - 1));
    }
    if (cv::norm(q[0] - q[1]) > 3 && cv::norm(q[0] - q[3]) > 3)
      quads.push_back(q);
  }
#if TARGET_OS_SIMULATOR
  if ([NSProcessInfo.processInfo.arguments containsObject:@"--photo-translation-probe"] &&
      [NSProcessInfo.processInfo.environment[@"OCR_PROBE_REDETECT"] isEqualToString:@"1"])
    quads = redetectRegions(img, quads, det, h, w);
#endif
  std::vector<cv::Mat> crops;
  if (quads.size() > 200)
    @throw [NSException exceptionWithName:@"image"
                                   reason:@"There is too much text in this photo. Choose a smaller "
                                          @"area in Photos and try again."
                                 userInfo:nil];
  for (auto q : quads)
    crops.push_back(crop(img, q));
  double post = clockNow();
  std::vector<size_t> indices(crops.size());
  std::iota(indices.begin(), indices.end(), 0);
  std::stable_sort(indices.begin(), indices.end(), [&](auto a, auto b) {
    return double(crops[a].cols) / crops[a].rows < double(crops[b].cols) / crops[b].rows;
  });
  NSMutableArray *texts = [NSMutableArray array], *scores = [NSMutableArray array];
  for (size_t i = 0; i < crops.size(); i++) {
    [texts addObject:@""];
    [scores addObject:@0];
  }
  double recInference = 0;
  for (size_t i = 0; i < indices.size(); i += 6) {
    // Release ORT output dictionaries and tensors before the next batch.
    @autoreleasepool {
      std::vector<cv::Mat> batch;
      double maxRatio = 320.0 / 48;
      for (size_t j = i; j < std::min(i + 6, indices.size()); j++) {
        batch.push_back(crops[indices[j]]);
        maxRatio = std::max(maxRatio, double(batch.back().cols) / batch.back().rows);
      }
      int bw = int(48 * maxRatio);
      // Do not allocate unbounded logits for an extremely thin, long text region.
      if (bw > 2048)
        @throw [NSException
            exceptionWithName:@"image"
                       reason:@"The image could not be recognized. Try a clearer or closer photo."
                     userInfo:nil];
      NSMutableData *in = tensor(batch, 48, bw, true);
      double t = clockNow();
      ORTValue *out = run(rec, in, @[ @(batch.size()), @3, @48, @(bw) ]);
      recInference += (clockNow() - t) * 1000;
      NSError *e = nil;
      NSArray *shape = [out tensorTypeAndShapeInfoWithError:&e].shape;
      fail(e);
      bool compact = shape.count == 3 && [shape[2] intValue] == 2;
      if (shape.count != 3 || (!compact && [shape[2] unsignedIntegerValue] != dict.count))
        @throw [NSException
            exceptionWithName:@"dictionary"
                       reason:[NSString stringWithFormat:@"output %@, dictionary %lu", shape,
                                                         (unsigned long)dict.count]
                     userInfo:nil];
      int steps = [shape[1] intValue], classes = [shape[2] intValue];
      NSMutableData *od = [out tensorDataWithError:&e];
      fail(e);
      const float *prob = (const float *)od.bytes;
      for (size_t b = 0; b < batch.size(); b++) {
        NSMutableString *text = [NSMutableString string];
        int previous = -1, count = 0;
        double confidence = 0;
        for (int t = 0; t < steps; t++) {
          const float *v = prob + (b * steps + t) * classes;
          int best = compact ? int(v[0]) : int(std::max_element(v, v + classes) - v);
          if (best < 0 || best >= (int)dict.count)
            @throw [NSException exceptionWithName:@"CTC index"
                                           reason:@"out of dictionary range"
                                         userInfo:nil];
          if (best != 0 && best != previous) {
            [text appendString:dict[best]];
            confidence += compact ? v[1] : v[best];
            count++;
          }
          previous = best;
        }
        texts[indices[i + b]] = text;
        scores[indices[i + b]] = @(count ? confidence / count : 0);
      }
      if (trace && i == 0) {
        [in writeToFile:[trace stringByAppendingString:@"-rec.bin"] atomically:YES];
        NSData *s = [NSJSONSerialization dataWithJSONObject:@{
          @"rec_shape" : @[ @(batch.size()), @3, @48, @(bw) ],
          @"det_shape" : @[ @1, @3, @(h), @(w) ]
        }
                                                    options:0
                                                      error:nil];
        [s writeToFile:[trace stringByAppendingString:@"-shapes.json"] atomically:YES];
      }
    }
  }
  double finished = clockNow();
  NSMutableArray *filtered = [NSMutableArray array], *coords = [NSMutableArray array],
                 *confs = [NSMutableArray array];
  for (size_t i = 0; i < quads.size(); i++) {
    if ([scores[i] doubleValue] < 0.5)
      continue;
    [filtered addObject:texts[i]];
    [confs addObject:scores[i]];
    NSMutableArray *q = [NSMutableArray array];
    for (auto p : quads[i])
      [q addObject:@[ @(p.x), @(p.y) ]];
    [coords addObject:q];
  }
  if (trace)
    [input writeToFile:[trace stringByAppendingString:@"-det.bin"] atomically:YES];
  double assembled = clockNow();
  return @{
    @"image_width" : @(img.cols),
    @"image_height" : @(img.rows),
    @"texts" : filtered,
    @"boxes" : coords,
    @"scores" : confs,
    @"detected_regions" : @(quads.size()),
    @"text_regions" : @(filtered.count),
    @"decode_ms" : @((decoded - start) * 1000),
    @"preprocess_ms" : @((prep - decoded) * 1000),
    @"det_inference_ms" : @((inferred - prep) * 1000),
    @"det_post_crop_ms" : @((post - inferred) * 1000),
    @"recognition_ms" : @((finished - post) * 1000),
    @"rec_inference_ms" : @(recInference),
    @"ocr_wall_ms" : @((assembled - decoded) * 1000),
    @"photo_total_ms" : @((assembled - start) * 1000)
  };
}

@implementation MROCRBridge
+ (NSDictionary<NSString *, id> *)recognizeImageAtPath:(NSString *)path
                                          detectorPath:(NSString *)detectorPath
                                        recognizerPath:(NSString *)recognizerPath
                                            dictionary:(NSArray<NSString *> *)dictionary
                                             cachePath:(NSString *)cachePath
                                                 error:(NSError **)error {
  NSDictionary *result = nil;
  NSError *failure = nil;
  @autoreleasepool {
    try {
      @try {
        cv::setNumThreads(1);
        NSError *e = nil;
        ORTEnv *env = [[ORTEnv alloc] initWithLoggingLevel:ORTLoggingLevelWarning error:&e];
        fail(e);
        ORTSessionOptions *options = [[ORTSessionOptions alloc] initWithError:&e];
        fail(e);
        [options setIntraOpNumThreads:2 error:&e];
        fail(e);
        [options addConfigEntryWithKey:@"session.enable_cpu_mem_arena" value:@"0" error:&e];
        fail(e);
        [options setGraphOptimizationLevel:ORTGraphOptimizationLevelAll error:&e];
        fail(e);
        ORTSessionOptions *detOptions = coreMLSessionOptions(cachePath, NO);
        ORTSession *det = [[ORTSession alloc] initWithEnv:env
                                                modelPath:detectorPath
                                           sessionOptions:detOptions
                                                    error:&e];
        fail(e);
        ORTSession *rec = [[ORTSession alloc] initWithEnv:env
                                                modelPath:recognizerPath
                                           sessionOptions:options
                                                    error:&e];
        fail(e);
        if (dictionary.count < 2)
          @throw [NSException exceptionWithName:@"dictionary"
                                         reason:@"Missing OCR dictionary"
                                       userInfo:nil];
        result = recognize(path, det, rec, dictionary, nil);
      } @catch (NSException *exception) {
        failure = [NSError
            errorWithDomain:@"MurmurOCR"
                       code:1
                   userInfo:@{NSLocalizedDescriptionKey : exception.reason ?: @"OCR failed"}];
      }
    } catch (const std::exception &exception) {
      failure = [NSError errorWithDomain:@"MurmurOCR"
                                    code:2
                                userInfo:@{NSLocalizedDescriptionKey : @(exception.what())}];
    }
  }
  if (error)
    *error = failure;
  return result;
}
@end

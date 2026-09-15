#import "../Headers/CoreMotionTracker.h"
#import <os/lock.h>
#import <cmath>

#define MOTION_BUFFER_CAPACITY 256

@interface MetalFGMotionTracker () {
    CMMotionManager *_motionManager;
    NSOperationQueue *_motionQueue;
    
    // Circular sample buffer
    MetalFGMotionSample _sampleBuffer[MOTION_BUFFER_CAPACITY];
    size_t _sampleHead;
    size_t _sampleCount;
    os_unfair_lock _lock;
    
    CFTimeInterval _timeOffset; // Synchronize CoreMotion timestamp with CACurrentMediaTime()
    BOOL _hasTimeOffset;
}

@property (nonatomic, readwrite) BOOL isRunning;

@end

@implementation MetalFGMotionTracker

+ (instancetype)sharedTracker {
    static MetalFGMotionTracker *sShared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sShared = [[MetalFGMotionTracker alloc] init];
    });
    return sShared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _motionManager = [[CMMotionManager alloc] init];
        _motionQueue = [[NSOperationQueue alloc] init];
        _motionQueue.name = @"com.metalfg.motionqueue";
        _motionQueue.qualityOfService = NSQualityOfServiceUserInteractive;
        _motionQueue.maxConcurrentOperationCount = 1;
        
        _updateInterval = 1.0 / 200.0; // 200Hz polling rate for sub-5ms latency
        _sampleHead = 0;
        _sampleCount = 0;
        _lock = OS_UNFAIR_LOCK_INIT;
        _hasTimeOffset = NO;
        _timeOffset = 0.0;
        _isRunning = NO;
    }
    return self;
}

- (BOOL)startTracking {
    if (self.isRunning) {
        return YES;
    }
    
    if (!_motionManager.isDeviceMotionAvailable) {
        NSLog(@"[MetalFG] CoreMotion: Device motion is not available on this device!");
        return NO;
    }
    
    _motionManager.deviceMotionUpdateInterval = _updateInterval;
    
    __weak MetalFGMotionTracker *weakSelf = self;
    [_motionManager startDeviceMotionUpdatesUsingReferenceFrame:CMAttitudeReferenceFrameXArbitraryCorrectedZVertical
                                                       toQueue:_motionQueue
                                                   withHandler:^(CMDeviceMotion * _Nullable motion, NSError * _Nullable error) {
        if (!motion || error) return;
        
        [weakSelf pushMotionSample:motion];
    }];
    
    _isRunning = YES;
    NSLog(@"[MetalFG] CoreMotionTracker started at %.1f Hz.", 1.0 / _updateInterval);
    return YES;
}

- (void)stopTracking {
    if (!self.isRunning) return;
    
    [_motionManager stopDeviceMotionUpdates];
    _isRunning = NO;
    
    os_unfair_lock_lock(&_lock);
    _sampleCount = 0;
    _sampleHead = 0;
    _hasTimeOffset = NO;
    os_unfair_lock_unlock(&_lock);
    
    NSLog(@"[MetalFG] CoreMotionTracker stopped.");
}

- (void)pushMotionSample:(CMDeviceMotion *)motion {
    CFTimeInterval nowMediaTime = CACurrentMediaTime();
    
    os_unfair_lock_lock(&_lock);
    
    // CoreMotion timestamps are referenced to system boot time (mach_absolute_time).
    // Synchronize offset to CACurrentMediaTime() for consistent presentation pacing.
    if (!_hasTimeOffset) {
        _timeOffset = nowMediaTime - motion.timestamp;
        _hasTimeOffset = YES;
    }
    
    CFTimeInterval synchronizedTimestamp = motion.timestamp + _timeOffset;
    
    // Extract quaternion: CMQuaternion (x, y, z, w)
    CMQuaternion cmQ = motion.attitude.quaternion;
    simd_quatf quat = simd_quaternion((float)cmQ.x, (float)cmQ.y, (float)cmQ.z, (float)cmQ.w);
    
    // Normalize quaternion to guarantee unit length
    quat = simd_normalize(quat);
    
    CMRotationRate rate = motion.rotationRate;
    simd_float3 angVel = simd_make_float3((float)rate.x, (float)rate.y, (float)rate.z);
    
    MetalFGMotionSample sample;
    sample.timestamp = synchronizedTimestamp;
    sample.orientation = quat;
    sample.angularVelocity = angVel;
    
    _sampleBuffer[_sampleHead] = sample;
    _sampleHead = (_sampleHead + 1) % MOTION_BUFFER_CAPACITY;
    if (_sampleCount < MOTION_BUFFER_CAPACITY) {
        _sampleCount++;
    }
    
    os_unfair_lock_unlock(&_lock);
}

- (simd_quatf)orientationAtTimestamp:(CFTimeInterval)timestamp {
    os_unfair_lock_lock(&_lock);
    
    if (_sampleCount == 0) {
        os_unfair_lock_unlock(&_lock);
        return simd_quaternion(0.0f, 0.0f, 0.0f, 1.0f); // Identity
    }
    
    // Most recent sample index
    size_t newestIdx = (_sampleHead + MOTION_BUFFER_CAPACITY - 1) % MOTION_BUFFER_CAPACITY;
    MetalFGMotionSample newest = _sampleBuffer[newestIdx];
    
    // Oldest sample index
    size_t oldestIdx = (_sampleHead + MOTION_BUFFER_CAPACITY - _sampleCount) % MOTION_BUFFER_CAPACITY;
    MetalFGMotionSample oldest = _sampleBuffer[oldestIdx];
    
    // 1. Timestamp is older than our history buffer: return oldest
    if (timestamp <= oldest.timestamp) {
        simd_quatf result = oldest.orientation;
        os_unfair_lock_unlock(&_lock);
        return result;
    }
    
    // 2. Timestamp is newer than our latest sample: extrapolate using angular velocity
    if (timestamp >= newest.timestamp) {
        float dt = (float)(timestamp - newest.timestamp);
        simd_quatf result = newest.orientation;
        
        // Extrapolate up to 50ms (prevents divergence during temporary thread stalls)
        if (dt > 0.0001f && dt < 0.050f) {
            simd_float3 omega = newest.angularVelocity;
            float speed = simd_length(omega);
            if (speed > 0.001f) {
                float angle = speed * dt;
                simd_float3 axis = omega / speed;
                simd_quatf deltaQ = simd_quaternion(angle, axis);
                result = simd_normalize(simd_mul(newest.orientation, deltaQ));
            }
        }
        os_unfair_lock_unlock(&_lock);
        return result;
    }
    
    // 3. Search backwards in circular buffer to find the enclosing interval [sA, sB]
    MetalFGMotionSample sA = oldest;
    MetalFGMotionSample sB = newest;
    
    for (size_t i = 0; i < _sampleCount - 1; ++i) {
        size_t idxB = (_sampleHead + MOTION_BUFFER_CAPACITY - 1 - i) % MOTION_BUFFER_CAPACITY;
        size_t idxA = (_sampleHead + MOTION_BUFFER_CAPACITY - 2 - i) % MOTION_BUFFER_CAPACITY;
        
        if (_sampleBuffer[idxA].timestamp <= timestamp && _sampleBuffer[idxB].timestamp >= timestamp) {
            sA = _sampleBuffer[idxA];
            sB = _sampleBuffer[idxB];
            break;
        }
    }
    
    os_unfair_lock_unlock(&_lock);
    
    // Spherical Linear Interpolation (SLERP)
    float span = (float)(sB.timestamp - sA.timestamp);
    if (span < 0.00001f) {
        return sB.orientation;
    }
    
    float alpha = (float)(timestamp - sA.timestamp) / span;
    alpha = fmaxf(0.0f, fminf(1.0f, alpha));
    
    return simd_slerp(sA.orientation, sB.orientation, alpha);
}

// Convert quaternion to 3x3 rotation matrix R
static simd_float3x3 simd_matrix3x3_from_quat(simd_quatf q) {
    float x = q.vector.x;
    float y = q.vector.y;
    float z = q.vector.z;
    float w = q.vector.w;
    
    float xx = x * x, yy = y * y, zz = z * z;
    float xy = x * y, xz = x * z, yz = y * z;
    float wx = w * x, wy = w * y, wz = w * z;
    
    simd_float3x3 m;
    // Column 0
    m.columns[0] = simd_make_float3(1.0f - 2.0f * (yy + zz),
                                    2.0f * (xy + wz),
                                    2.0f * (xz - wy));
    // Column 1
    m.columns[1] = simd_make_float3(2.0f * (xy - wz),
                                    1.0f - 2.0f * (xx + zz),
                                    2.0f * (yz + wx));
    // Column 2
    m.columns[2] = simd_make_float3(2.0f * (xz + wy),
                                    2.0f * (yz - wx),
                                    1.0f - 2.0f * (xx + yy));
    return m;
}

- (simd_float3x3)computeHomographyFromBase:(simd_quatf)baseQuat
                                  toTarget:(simd_quatf)targetQuat
                               fovYDegrees:(float)fovYDegrees
                               aspectRatio:(float)aspectRatio
                               orientation:(UIInterfaceOrientation)interfaceOrientation {
    // Relative rotation in device coordinate space:
    // deltaQ transforms vectors from target orientation to base orientation
    // deltaQ = targetQuat * baseQuat^-1
    simd_quatf deltaQ = simd_mul(targetQuat, simd_conjugate(baseQuat));
    deltaQ = simd_normalize(deltaQ);
    
    // Adjust device coordinates for display orientation
    // Device frame: +X Right, +Y Top, +Z Screen towards user
    simd_quatf alignQuat;
    switch (interfaceOrientation) {
        case UIInterfaceOrientationLandscapeLeft:
            // Screen rotated 90 deg clockwise (home button on left)
            alignQuat = simd_quaternion((float)(-M_PI_2), simd_make_float3(0.0f, 0.0f, 1.0f));
            break;
        case UIInterfaceOrientationLandscapeRight:
            // Screen rotated 90 deg counter-clockwise (home button on right)
            alignQuat = simd_quaternion((float)(M_PI_2), simd_make_float3(0.0f, 0.0f, 1.0f));
            break;
        case UIInterfaceOrientationPortraitUpsideDown:
            alignQuat = simd_quaternion((float)(M_PI), simd_make_float3(0.0f, 0.0f, 1.0f));
            break;
        case UIInterfaceOrientationPortrait:
        default:
            alignQuat = simd_quaternion(0.0f, simd_make_float3(0.0f, 0.0f, 1.0f));
            break;
    }
    
    // Transform delta rotation into camera viewport space
    simd_quatf camDeltaQ = simd_mul(alignQuat, simd_mul(deltaQ, simd_conjugate(alignQuat)));
    camDeltaQ = simd_normalize(camDeltaQ);
    
    // Rotation matrix in 3D camera space
    simd_float3x3 R = simd_matrix3x3_from_quat(camDeltaQ);
    
    // Camera Intrinsic Projection Matrix K (in NDC coordinates)
    float fovYRad = (fovYDegrees > 10.0f ? fovYDegrees : 75.0f) * (float)(M_PI / 180.0);
    float fy = 1.0f / tanf(fovYRad * 0.5f);
    float fx = fy / (aspectRatio > 0.1f ? aspectRatio : (16.0f / 9.0f));
    
    // R_transpose = inverse of rotation matrix R
    // R is orthogonal, so R^T = R^-1
    // Homography H = K * R^T * K^-1
    // Let M = R^T. In column-major SIMD:
    // M[row][col] = R[col][row]
    // Since K = diag(fx, fy, 1) and K^-1 = diag(1/fx, 1/fy, 1):
    // H[i][j] = K[i] * M[i][j] * (1 / K[j])
    
    float M00 = R.columns[0].x, M01 = R.columns[0].y, M02 = R.columns[0].z;
    float M10 = R.columns[1].x, M11 = R.columns[1].y, M12 = R.columns[1].z;
    float M20 = R.columns[2].x, M21 = R.columns[2].y, M22 = R.columns[2].z;
    
    simd_float3x3 H;
    // Column 0 (maps target x)
    H.columns[0] = simd_make_float3(M00,
                                    (fy / fx) * M10,
                                    (1.0f / fx) * M20);
    // Column 1 (maps target y)
    H.columns[1] = simd_make_float3((fx / fy) * M01,
                                    M11,
                                    (1.0f / fy) * M21);
    // Column 2 (maps target w=1)
    H.columns[2] = simd_make_float3(fx * M02,
                                    fy * M12,
                                    M22);
    
    return H;
}

- (simd_float3x3)invertMatrix3x3:(simd_float3x3)m {
    // Standard 3x3 matrix inverse using adjugate / determinant
    float c00 = m.columns[1].y * m.columns[2].z - m.columns[1].z * m.columns[2].y;
    float c01 = m.columns[1].z * m.columns[2].x - m.columns[1].x * m.columns[2].z;
    float c02 = m.columns[1].x * m.columns[2].y - m.columns[1].y * m.columns[2].x;
    
    float det = m.columns[0].x * c00 + m.columns[0].y * c01 + m.columns[0].z * c02;
    if (fabsf(det) < 1e-6f) {
        // Singular matrix, return identity
        simd_float3x3 id;
        id.columns[0] = simd_make_float3(1, 0, 0);
        id.columns[1] = simd_make_float3(0, 1, 0);
        id.columns[2] = simd_make_float3(0, 0, 1);
        return id;
    }
    
    float invDet = 1.0f / det;
    simd_float3x3 inv;
    
    inv.columns[0] = simd_make_float3(c00 * invDet,
                                      (m.columns[0].z * m.columns[2].y - m.columns[0].y * m.columns[2].z) * invDet,
                                      (m.columns[0].y * m.columns[1].z - m.columns[0].z * m.columns[1].y) * invDet);
    
    inv.columns[1] = simd_make_float3(c01 * invDet,
                                      (m.columns[0].x * m.columns[2].z - m.columns[0].z * m.columns[2].x) * invDet,
                                      (m.columns[0].z * m.columns[1].x - m.columns[0].x * m.columns[1].z) * invDet);
    
    inv.columns[2] = simd_make_float3(c02 * invDet,
                                      (m.columns[0].y * m.columns[2].x - m.columns[0].x * m.columns[2].y) * invDet,
                                      (m.columns[0].x * m.columns[1].y - m.columns[0].y * m.columns[1].x) * invDet);
    return inv;
}

@end


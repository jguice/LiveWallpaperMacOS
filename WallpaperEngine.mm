/*
 * This file is part of LiveWallpaper – LiveWallpaper App for macOS.
 * Copyright (C) 2025 Bios thusvill
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

#import "WallpaperEngine.h"
#include "DisplayObjc.h"
#include "SaveSystem.h"
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#include <filesystem>
#import <mach/mach.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

namespace fs = std::filesystem;

extern char **environ;

#define THUMBNAIL_QUALITY_FACTOR 0.05f
// Long-edge pixel size for grid thumbnails. The old 5%-of-source factor made
// ~96px images that upscaled to a blurry mess on Retina; a fixed ~800px long
// edge stays crisp for the grid tiles at 2x/3x while keeping PNGs small.
#define THUMBNAIL_MAX_DIMENSION 800.0f
#define QUALITY_BADGE_FONT_SIZE 48.0f

static NSString *folderPath = nil;

@implementation WallpaperEngine {
@private
  dispatch_queue_t _wallpaperQueue;
  dispatch_queue_t _thumbnailQueue;
  dispatch_semaphore_t _wallpaperSemaphore;
}

+ (instancetype)sharedEngine {
  static WallpaperEngine *sharedInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = [[self alloc] init];
  });
  return sharedInstance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _generatingImages = NO;
    _generatingThumbImages = NO;
    _currentVideoPath = nil;
    _daemonPIDs = std::list<pid_t>();

    _wallpaperQueue = dispatch_queue_create("com.livewallpaper.wallpaperQueue",
                                            DISPATCH_QUEUE_CONCURRENT);
    _thumbnailQueue = dispatch_queue_create("com.livewallpaper.thumbnailQueue",
                                            DISPATCH_QUEUE_SERIAL);

    _wallpaperSemaphore = dispatch_semaphore_create(2);
      _currentWallpaper = 0;
      _wallpaperList = [NSMutableArray array];
      
    ScanDisplays();

    displays = SaveSystem::Load();
    [self migrateLegacyLaunchState];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
      
      _rotationType = (RotationType)[defaults integerForKey:@"rtype"];
      
      _rotationDelay = (int)[defaults integerForKey:@"rdelay"];
      
      if(_rotationType == 0){
          _rotationType = RotationTypeSequential;
      }
      if(_rotationDelay < 50){
          _rotationDelay = 60;
      }
      if([defaults boolForKey:@"rotation"]){
          [self startWallpaperRotation];
      }
      

    for (Display display : displays) {
      if ([defaults boolForKey:@"random"]) {
        [self randomWallpapersLid];
      } else {
        if (!display.videoPath.empty()) {
          // Install the launchd agent only if it's missing; if it already exists
          // launchd is rendering it via RunAtLoad and we must not restart it.
          [self ensureAgentForUUID:[NSString stringWithUTF8String:display.uuid
                                                                      .c_str()]
                         videoPath:[NSString stringWithUTF8String:display.videoPath
                                                                      .c_str()]
                         imagePath:[NSString stringWithUTF8String:display.framePath
                                                                      .c_str()]];
        }
      }
    }
  }
  return self;
}

- (void)randomWallpapersLid {

  NSLog(@"Applying Random Wallpapers!");

  for (Display display : displays) {

    if (!display.videoPath.empty()) {
      CGDirectDisplayID displayID = DisplayIDFromUUID(display.uuid);

      [self startWallpaperWithPath:
                [self getRandomVideoFileFromFolder:[self getFolderPath]]
                        onDisplays:@[ @(displayID) ]];
    }
  }
}

- (NSString *)getRandomVideoFileFromFolder:(NSString *)folderPath {
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSError *error = nil;

  NSArray<NSString *> *allFiles =
      [fileManager contentsOfDirectoryAtPath:folderPath error:&error];

  if (error) {
    NSLog(@"Error reading directory: %@", error.localizedDescription);
    return nil;
  }

  NSMutableArray<NSString *> *videoFiles = [NSMutableArray array];

  for (NSString *fileName in allFiles) {
    NSString *fileExtension = [[fileName pathExtension] lowercaseString];

    if ([fileExtension isEqualToString:@"mp4"] ||
        [fileExtension isEqualToString:@"mov"]) {
      NSString *fullPath = [folderPath stringByAppendingPathComponent:fileName];
      [videoFiles addObject:fullPath];
    }
  }

  if (videoFiles.count == 0) {
    return nil;
  }

  NSUInteger randomIndex = arc4random_uniform((uint32_t)videoFiles.count);
  return videoFiles[randomIndex];
}

- (void)dealloc {
  [self removeNotifications];
}

- (void)setupNotifications {
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(screensDidChange:)
             name:NSApplicationDidChangeScreenParametersNotification
           object:nil];

  [[[NSWorkspace sharedWorkspace] notificationCenter]
      addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification
                  object:nil
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification *_Nonnull note) {
                [self handleSpaceChange:note];
              }];

  [[NSWorkspace sharedWorkspace].notificationCenter
      addObserverForName:NSWorkspaceDidWakeNotification
                  object:nil
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification *_Nonnull note) {
                [self awakeHandle:note];
              }];
}

- (void)removeNotifications {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
  [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleSpaceChange:(NSNotification *)note {
  CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFSTR("com.live.wallpaper.spaceChanged"), NULL, NULL, true);
}

- (void)awakeHandle:(NSNotification *)note {
  // random_lid: re-randomize wallpapers on wake. Otherwise there is nothing to
  // do — launchd (KeepAlive) owns the daemon's lifecycle, not this app.
  if ([[NSUserDefaults standardUserDefaults] floatForKey:@"random_lid"]) {
    NSLog(@"Screen Aweaked!");
    [self randomWallpapersLid];
  }
}

- (void)screensDidChange:(NSNotification *)note {
  NSLog(@"Screens changed");
  ScanDisplays();

  // Authoritative set of currently-connected display UUIDs. Use the ONLINE list
  // (connected, includes asleep) not the ACTIVE list (awake only): an idle-slept
  // display must stay "live" so reconcile doesn't delete its agent and kill the
  // wallpaper — it comes back by itself on wake.
  NSMutableSet<NSString *> *liveUUIDs = [NSMutableSet set];
  uint32_t count = 0;
  CGGetOnlineDisplayList(0, NULL, &count);
  if (count == 0) {
    return;  // transient mid sleep/wake; don't tear down agents
  }
  CGDirectDisplayID ids[count];
  CGGetOnlineDisplayList(count, ids, &count);
  for (uint32_t i = 0; i < count; i++) {
    std::string u = DisplayUUIDFromID(ids[i]);
    if (!u.empty())
      [liveUUIDs addObject:[NSString stringWithUTF8String:u.c_str()]];
  }

  // Ensure an agent exists for each connected display that has a saved video.
  // ensure (install-if-missing) avoids restarting the wallpaper on a plain
  // display sleep/wake — this notification also fires for those.
  for (Display display : displays) {
    NSString *uuid = [NSString stringWithUTF8String:display.uuid.c_str()];
    if ([liveUUIDs containsObject:uuid] && !display.videoPath.empty()) {
      [self ensureAgentForUUID:uuid
                     videoPath:[NSString stringWithUTF8String:display.videoPath
                                                                  .c_str()]
                     imagePath:[NSString stringWithUTF8String:display.framePath
                                                                  .c_str()]];
    }
  }
  // Remove agents for displays that are no longer connected (else they fall back
  // to and hijack the main screen).
  [self reconcileAgentsWithLiveUUIDs:liveUUIDs];
}

- (NSString *)thumbnailCachePath {
  NSArray *cacheDirs = NSSearchPathForDirectoriesInDomains(
      NSCachesDirectory, NSUserDomainMask, YES);
  NSString *systemCacheDir = cacheDirs.firstObject;
  NSString *bundleName =
      [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];

  if (!bundleName || bundleName.length == 0) {
    bundleName = @"LiveWallpaper";
  }

  NSString *thumbnailPath = [systemCacheDir
      stringByAppendingPathComponent:[NSString
                                         stringWithFormat:@"%@/thumbnails",
                                                          bundleName]];

  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:thumbnailPath]) {
    [fm createDirectoryAtPath:thumbnailPath
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
  }

  return thumbnailPath;
}

- (NSString *)staticWallpaperCachePath {
  NSArray *cacheDirs = NSSearchPathForDirectoriesInDomains(
      NSCachesDirectory, NSUserDomainMask, YES);
  NSString *systemCacheDir = cacheDirs.firstObject;
  NSString *bundleName =
      [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];

  if (!bundleName || bundleName.length == 0) {
    bundleName = @"LiveWallpaper";
  }

  NSString *wallpapersPath = [systemCacheDir
      stringByAppendingPathComponent:[NSString
                                         stringWithFormat:@"%@/wallpapers",
                                                          bundleName]];

  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:wallpapersPath]) {
    [fm createDirectoryAtPath:wallpapersPath
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
  }

  return wallpapersPath;
}

- (void)clearCache {
  NSFileManager *fileManager = [NSFileManager defaultManager];

  NSString *thumbnailPath = [self thumbnailCachePath];
  if ([fileManager fileExistsAtPath:thumbnailPath]) {
    NSError *error = nil;
    NSArray *files = [fileManager contentsOfDirectoryAtPath:thumbnailPath
                                                      error:&error];
    if (!error) {
      for (NSString *file in files) {
        NSString *filePath =
            [thumbnailPath stringByAppendingPathComponent:file];
        [fileManager removeItemAtPath:filePath error:nil];
      }
    }
  }

  NSString *staticPath = [self staticWallpaperCachePath];
  if ([fileManager fileExistsAtPath:staticPath]) {
    NSError *error = nil;
    NSArray *files = [fileManager contentsOfDirectoryAtPath:staticPath
                                                      error:&error];
    if (!error) {
      for (NSString *file in files) {
        NSString *filePath = [staticPath stringByAppendingPathComponent:file];
        [fileManager removeItemAtPath:filePath error:nil];
      }
    }
  }

  NSString *appSupportDir = [NSSearchPathForDirectoriesInDomains(
      NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
  NSString *customDir =
      [appSupportDir stringByAppendingPathComponent:@"Livewall"];

  [fileManager createDirectoryAtPath:customDir
         withIntermediateDirectories:YES
                          attributes:nil
                               error:nil];

  if ([fileManager fileExistsAtPath:customDir]) {
    NSError *error = nil;
    NSArray *files = [fileManager contentsOfDirectoryAtPath:customDir
                                                      error:&error];
    if (!error) {
      for (NSString *file in files) {
        NSString *filePath = [customDir stringByAppendingPathComponent:file];
        [fileManager removeItemAtPath:filePath error:nil];
      }
    }
  }
}
- (void)generateThumbnails {
  if (!_generatingThumbImages) {
    [self generateThumbnailsForFolder:[self getFolderPath]
                       withCompletion:^{
                         dispatch_async(dispatch_get_main_queue(), ^{
                           [[NSNotificationCenter defaultCenter]
                               postNotificationName:@"ThumbnailsGenerated"
                                             object:nil];
                         });
                       }];
  }
}
- (void)resetUserData {
  NSString *appDomain = [[NSBundle mainBundle] bundleIdentifier];
  [[NSUserDefaults standardUserDefaults]
      removePersistentDomainForName:appDomain];
  [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)generateStaticWallpapersForFolder:(NSString *)folderPath
                           withCompletion:(void (^)(void))completion {
  if (_generatingImages) {
    if (completion)
      completion();
    return;
  }

  _generatingImages = YES;
  NSLog(@"Generating static wallpapers...");

  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSString *wallpaperCachePath = [self staticWallpaperCachePath];

  if (!folderPath) {
    folderPath = [self getFolderPath];
  }

  if (![fileManager fileExistsAtPath:wallpaperCachePath]) {
    [fileManager createDirectoryAtPath:wallpaperCachePath
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:nil];
  }

  NSArray<NSString *> *files = [fileManager contentsOfDirectoryAtPath:folderPath
                                                                error:nil];
  if (files.count == 0) {
    NSLog(@"No files found in folder: %@", folderPath);
    _generatingImages = NO;
    if (completion)
      completion();
    return;
  }

  __block NSInteger completedCount = 0;
  NSInteger totalCount = 0;

  for (NSString *filename in files) {
    if (![filename.pathExtension.lowercaseString isEqualToString:@"mp4"] &&
        ![filename.pathExtension.lowercaseString isEqualToString:@"mov"]) {
      continue;
    }
    totalCount++;

    dispatch_async(_wallpaperQueue, ^{
      dispatch_semaphore_wait(self->_wallpaperSemaphore, DISPATCH_TIME_FOREVER);

      @autoreleasepool {
        NSString *filePath =
            [folderPath stringByAppendingPathComponent:filename];
        NSURL *videoURL = [NSURL fileURLWithPath:filePath];

        AVAsset *asset = [AVAsset assetWithURL:videoURL];

        [asset
            loadValuesAsynchronouslyForKeys:@[ @"tracks" ]
                          completionHandler:^{
                            AVKeyValueStatus status =
                                [asset statusOfValueForKey:@"tracks" error:nil];
                            if (status != AVKeyValueStatusLoaded) {
                              NSLog(@"Failed to load tracks for %@", filename);
                              completedCount++;
                              dispatch_semaphore_signal(
                                  self->_wallpaperSemaphore);
                              return;
                            }

                            [self generateStaticImageFromAsset:asset
                                                      filename:filename
                                                 wallpaperPath:
                                                     wallpaperCachePath];

                            completedCount++;

                            if (completedCount >= totalCount) {
                              self->_generatingImages = NO;
                              if (completion) {
                                dispatch_async(dispatch_get_main_queue(),
                                               completion);
                              }
                            }

                            dispatch_semaphore_signal(
                                self->_wallpaperSemaphore);
                          }];
      }
    });
  }

  if (totalCount == 0) {
    _generatingImages = NO;
    if (completion)
      completion();
  }
}

- (void)generateStaticImageFromAsset:(AVAsset *)asset
                            filename:(NSString *)filename
                       wallpaperPath:(NSString *)wallpaperPath {
  AVAssetImageGenerator *generator =
      [[AVAssetImageGenerator alloc] initWithAsset:asset];
  generator.appliesPreferredTrackTransform = YES;

  NSArray<AVAssetTrack *> *videoTracks =
      [asset tracksWithMediaType:AVMediaTypeVideo];

  if (videoTracks.count > 0) {
    AVAssetTrack *track = videoTracks.firstObject;
    CGSize videoSize = track.naturalSize;
    CGAffineTransform transform = track.preferredTransform;
    CGSize renderSize = CGSizeApplyAffineTransform(videoSize, transform);
    generator.maximumSize =
        CGSizeMake(fabs(renderSize.width), fabs(renderSize.height));
  }

  Float64 midpointSec = CMTimeGetSeconds(asset.duration) / 2.0;
  CMTime midpoint =
      CMTimeMakeWithSeconds(midpointSec, asset.duration.timescale);

  [generator
      generateCGImagesAsynchronouslyForTimes:@[ [NSValue
                                                 valueWithCMTime:midpoint] ]
                           completionHandler:^(
                               CMTime requestedTime, CGImageRef image,
                               CMTime actualTime,
                               AVAssetImageGeneratorResult result,
                               NSError *error) {
                             if (result == AVAssetImageGeneratorSucceeded &&
                                 image != NULL) {
                               CGImageRef retainedImage =
                                   CGImageCreateCopy(image);

                               NSString *thumbName =
                                   [[filename stringByDeletingPathExtension]
                                       stringByAppendingPathExtension:@"png"];
                               NSString *thumbPath = [wallpaperPath
                                   stringByAppendingPathComponent:thumbName];
                               NSURL *thumbURL =
                                   [NSURL fileURLWithPath:thumbPath];

                               CGImageDestinationRef dest =
                                   CGImageDestinationCreateWithURL(
                                       (__bridge CFURLRef)thumbURL,
                                       (__bridge CFStringRef)
                                           UTTypePNG.identifier,
                                       1, NULL);

                               if (dest) {
                                 CGImageDestinationAddImage(dest, retainedImage,
                                                            NULL);
                                 CGImageDestinationFinalize(dest);
                                 CFRelease(dest);
                               }

                               CGImageRelease(retainedImage);
                             }
                           }];
}

- (void)generateThumbnailsForFolder:(NSString *)folderPath
                     withCompletion:(void (^)(void))completion {

  // Use atomic operation to prevent race condition
  @synchronized(self) {
    if (_generatingThumbImages) {
      NSLog(@"Thumbnail generation already in progress, skipping...");
      if (completion)
        completion();
      return;
    }
    _generatingThumbImages = YES;
  }

  NSString *thumbnailCachePath = [self thumbnailCachePath];
  NSLog(@"Generating Thumbnails in %@ ...", thumbnailCachePath);

  NSFileManager *fileManager = [NSFileManager defaultManager];

  if (![fileManager fileExistsAtPath:thumbnailCachePath]) {
    [fileManager createDirectoryAtPath:thumbnailCachePath
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:nil];
  }

  NSArray<NSString *> *files = [fileManager contentsOfDirectoryAtPath:folderPath
                                                                error:nil];
  if (files.count == 0) {
    NSLog(@"No files found in folder: %@", folderPath);
    _generatingThumbImages = NO;
    if (completion)
      completion();
    return;
  }

  // Filter video files and check which need thumbnails
  NSMutableArray<NSString *> *filesToProcess = [NSMutableArray array];
  for (NSString *filename in files) {
    if (![filename.pathExtension.lowercaseString isEqualToString:@"mp4"] &&
        ![filename.pathExtension.lowercaseString isEqualToString:@"mov"]) {
      continue;
    }

    // Check if thumbnail already exists
    NSString *thumbName = [[filename stringByDeletingPathExtension]
        stringByAppendingPathExtension:@"png"];
    NSString *thumbPath =
        [thumbnailCachePath stringByAppendingPathComponent:thumbName];

    BOOL isDir;
    NSLog(@"THUMB CHECK:\n  filename: %@\n  thumbPath: %@\n  exists: %d isDir: "
          @"%d",
          filename, thumbPath,
          [fileManager fileExistsAtPath:thumbPath isDirectory:&isDir], isDir);

    if (![fileManager fileExistsAtPath:thumbPath]) {
      [filesToProcess addObject:filename];
    }
  }

  if (filesToProcess.count == 0) {
    NSLog(@"All thumbnails already exist");
    _generatingThumbImages = NO;
    if (completion)
      completion();
    return;
  }

  NSLog(@"Processing %lu videos for thumbnails",
        (unsigned long)filesToProcess.count);

  // Use block-scoped variable for counting
  __block NSInteger completedCount = 0;
  NSInteger totalCount = filesToProcess.count;

  for (NSString *filename in filesToProcess) {
    dispatch_async(_thumbnailQueue, ^{
      @autoreleasepool {
        NSString *filePath =
            [folderPath stringByAppendingPathComponent:filename];
        NSURL *videoURL = [NSURL fileURLWithPath:filePath];

        if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
          NSLog(@"Video not found: %@", filePath);

          @synchronized(self) {
            completedCount++;
            if (completedCount >= totalCount) {
              self->_generatingThumbImages = NO;
              if (completion) {
                dispatch_async(dispatch_get_main_queue(), completion);
              }
            }
          }
          return;
        }

        AVAsset *asset = [AVAsset assetWithURL:videoURL];

        [asset loadValuesAsynchronouslyForKeys:@[ @"tracks", @"duration" ]
                             completionHandler:^{
                               [self processThumbnailForAsset:asset
                                                     filename:filename
                                                     videoURL:videoURL
                                               completedCount:&completedCount
                                                   totalCount:totalCount
                                                thumbnailPath:thumbnailCachePath
                                                   completion:completion];
                             }];
      }
    });
  }
}
- (void)processThumbnailForAsset:(AVAsset *)asset
                        filename:(NSString *)filename
                        videoURL:(NSURL *)videoURL
                  completedCount:(NSInteger *)completedCount
                      totalCount:(NSInteger)totalCount
                   thumbnailPath:(NSString *)thumbnailPath
                      completion:(void (^)(void))completion {

  NSError *error = nil;

  AVKeyValueStatus trackStatus = [asset statusOfValueForKey:@"tracks"
                                                      error:&error];
  AVKeyValueStatus durationStatus = [asset statusOfValueForKey:@"duration"
                                                         error:&error];

  if (trackStatus != AVKeyValueStatusLoaded ||
      durationStatus != AVKeyValueStatusLoaded) {
    NSLog(@"Failed to load asset metadata for %@: %@", filename,
          error.localizedDescription);

    @synchronized(self) {
      (*completedCount)++;
      if (*completedCount >= totalCount) {
        self->_generatingThumbImages = NO;
        if (completion) {
          dispatch_async(dispatch_get_main_queue(), completion);
        }
      }
    }
    return;
  }

  AVAssetImageGenerator *generator =
      [[AVAssetImageGenerator alloc] initWithAsset:asset];
  generator.appliesPreferredTrackTransform = YES;

  NSArray<AVAssetTrack *> *videoTracks =
      [asset tracksWithMediaType:AVMediaTypeVideo];
  if (videoTracks.count == 0) {
    NSLog(@"No video track for %@", filename);

    @synchronized(self) {
      (*completedCount)++;
      if (*completedCount >= totalCount) {
        self->_generatingThumbImages = NO;
        if (completion) {
          dispatch_async(dispatch_get_main_queue(), completion);
        }
      }
    }
    return;
  }

  // appliesPreferredTrackTransform (set above) handles orientation; maximumSize
  // preserves aspect ratio and fits the image within the box, so a square target
  // yields a long edge of ~THUMBNAIL_MAX_DIMENSION regardless of source size.
  generator.maximumSize =
      CGSizeMake(THUMBNAIL_MAX_DIMENSION, THUMBNAIL_MAX_DIMENSION);

  Float64 midpoint = CMTimeGetSeconds(asset.duration) / 2.0;
  CMTime targetTime = CMTimeMakeWithSeconds(midpoint, asset.duration.timescale);

  NSString *thumbName = [[filename stringByDeletingPathExtension]
      stringByAppendingPathExtension:@"png"];
  NSString *thumbPath =
      [thumbnailPath stringByAppendingPathComponent:thumbName];
  NSURL *thumbURL = [NSURL fileURLWithPath:thumbPath];

  [generator
      generateCGImagesAsynchronouslyForTimes:@[ [NSValue
                                                 valueWithCMTime:targetTime] ]
                           completionHandler:^(
                               CMTime requestedTime, CGImageRef cgImage,
                               CMTime actualTime,
                               AVAssetImageGeneratorResult result,
                               NSError *imgError) {
                             if (result == AVAssetImageGeneratorSucceeded &&
                                 cgImage != NULL) {
                               CGImageRef copy = CGImageCreateCopy(cgImage);

                               CGImageDestinationRef dest =
                                   CGImageDestinationCreateWithURL(
                                       (__bridge CFURLRef)thumbURL,
                                       (__bridge CFStringRef)
                                           UTTypePNG.identifier,
                                       1, NULL);

                               if (dest) {
                                 CGImageDestinationAddImage(dest, copy, NULL);
                                 CGImageDestinationFinalize(dest);
                                 CFRelease(dest);
                               }

                               CGImageRelease(copy);

                             } else {
                               NSLog(@"Thumbnail generation failed for %@: %@",
                                     filename, imgError.localizedDescription);
                             }

                             @synchronized(self) {
                               (*completedCount)++;
                               if (*completedCount >= totalCount) {
                                 self->_generatingThumbImages = NO;
                                 if (completion) {
                                   dispatch_async(dispatch_get_main_queue(),
                                                  completion);
                                 }
                               }
                             }
                           }];
}

- (void)saveThumbnailImage:(CGImageRef)image
                  filename:(NSString *)filename
             thumbnailPath:(NSString *)thumbnailPath {

  if (!image)
    return;

  CGImageRef safeImage = CGImageCreateCopy(image);

  // Save synchronously on thumbnail queue to ensure file is written before
  // completion
  @autoreleasepool {
    if (!safeImage)
      return;

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:thumbnailPath]) {
      NSError *err = nil;
      [fm createDirectoryAtPath:thumbnailPath
          withIntermediateDirectories:YES
                           attributes:nil
                                error:&err];
      if (err) {
        NSLog(@"Failed to create thumbnail folder: %@", err);
        CGImageRelease(safeImage);
        return;
      }
    }

    NSString *thumbName = [[filename stringByDeletingPathExtension]
        stringByAppendingPathExtension:@"png"];
    NSString *thumbPath =
        [thumbnailPath stringByAppendingPathComponent:thumbName];
    NSURL *thumbURL = [NSURL fileURLWithPath:thumbPath];

    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)thumbURL, kUTTypePNG, 1, NULL);

    if (!destination) {
      NSLog(@"Failed to create CGImageDestination for %@", thumbName);
      CGImageRelease(safeImage);
      return;
    }

    NSDictionary *options = @{
      (__bridge id)
      kCGImageDestinationLossyCompressionQuality : @(THUMBNAIL_QUALITY_FACTOR)
    };

    CGImageDestinationAddImage(destination, safeImage,
                               (__bridge CFDictionaryRef)options);

    if (!CGImageDestinationFinalize(destination)) {
      NSLog(@"Failed to write PNG thumbnail: %@", thumbName);
    } else {
      NSLog(@"Saved PNG thumbnail: %@", thumbName);

      // Post notification that this specific thumbnail is ready
      dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"ThumbnailSaved"
                          object:nil
                        userInfo:@{@"path" : thumbPath}];
      });
    }

    CFRelease(destination);
    CGImageRelease(safeImage);
  }
}

- (void)videoQualityBadgeForURL:(NSURL *)url
                     completion:(void (^)(NSString *badge))completion {
  AVAsset *asset = [AVAsset assetWithURL:url];

  if (@available(macOS 15.0, *)) {

    [asset loadTracksWithMediaType:AVMediaTypeVideo
                 completionHandler:^(NSArray<AVAssetTrack *> *tracks,
                                     NSError *error) {
                   NSString *badge = @"";

                   if (!error && tracks.count > 0) {
                     AVAssetTrack *videoTrack = tracks.firstObject;
                     badge = [self badgeFromVideoTrack:videoTrack];
                   }
                   dispatch_async(dispatch_get_main_queue(), ^{
                     completion(badge);
                   });
                 }];

  } else {

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AVAssetTrack *videoTrack =
        [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
#pragma clang diagnostic pop

    NSString *badge = videoTrack ? [self badgeFromVideoTrack:videoTrack] : @"";
    completion(badge);
  }
}

- (NSString *)badgeFromVideoTrack:(AVAssetTrack *)videoTrack {
  CGSize resolution = CGSizeApplyAffineTransform(videoTrack.naturalSize,
                                                 videoTrack.preferredTransform);

  resolution.width = fabs(resolution.width);
  resolution.height = fabs(resolution.height);

  if (resolution.width >= 3840 || resolution.height >= 2160)
    return @"4K";
  if (resolution.width >= 1920 || resolution.height >= 1080)
    return @"HD";
  if (resolution.width >= 1280 || resolution.height >= 720)
    return @"SD";

  return @"";
}

- (NSImage *)image:(NSImage *)image withBadge:(NSString *)badge {
  NSImage *result = [image copy];
  [result lockFocus];

  NSDictionary *attributes = @{
    NSFontAttributeName : [NSFont boldSystemFontOfSize:QUALITY_BADGE_FONT_SIZE],
    NSForegroundColorAttributeName : [NSColor whiteColor],
    NSStrokeColorAttributeName : [NSColor blackColor],
    NSStrokeWidthAttributeName : @-2
  };

  NSSize textSize = [badge sizeWithAttributes:attributes];

  CGFloat padding = 8;
  CGFloat verticalPadding = 6;
  CGFloat cornerRadius = 8;
  CGFloat marginRight = 10;
  CGFloat marginBottom = 10;

  NSColor *bgColor = [[NSColor blackColor] colorWithAlphaComponent:0.55];
  NSRect bgRect = NSMakeRect(
      result.size.width - textSize.width - padding * 2 - marginRight,
      result.size.height - textSize.height - verticalPadding * 2 - marginBottom,
      textSize.width + padding * 2, textSize.height + verticalPadding * 2);

  NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:bgRect
                                                       xRadius:cornerRadius
                                                       yRadius:cornerRadius];
  [bgColor setFill];
  [path fill];

  NSPoint textPoint = NSMakePoint(
      result.size.width - textSize.width - padding - marginRight,
      result.size.height - textSize.height - verticalPadding - marginBottom);
  [badge drawAtPoint:textPoint withAttributes:attributes];

  [result unlockFocus];
  return result;
}

- (BOOL)enableAppAsLoginItem {
  NSString *agentPath = [NSHomeDirectory()
      stringByAppendingPathComponent:
          @"Library/LaunchAgents/com.thusvill.LiveWallpaper.plist"];

  NSString *execPath = [[NSBundle mainBundle] executablePath];

  NSDictionary *plist = @{
    @"Label" : @"com.thusvill.LiveWallpaper",
    @"ProgramArguments" : @[ execPath ],
    @"RunAtLoad" : @YES,
    @"KeepAlive" : @NO
  };

  NSError *error = nil;
  NSData *plistData = [NSPropertyListSerialization
      dataWithPropertyList:plist
                    format:NSPropertyListXMLFormat_v1_0
                   options:0
                     error:&error];

  if (!plistData) {
    NSLog(@"Failed to serialize plist: %@", error);
    return NO;
  }

  if (![plistData writeToFile:agentPath atomically:YES]) {
    NSLog(@"Failed to write LaunchAgent");
    return NO;
  }

  NSTask *task = [[NSTask alloc] init];
  task.launchPath = @"/bin/launchctl";
  task.arguments = @[ @"load", agentPath ];
  [task launch];

  NSLog(@"Successfully registered app as login item");
  return YES;
}

- (void)startWallpaperWithPath:(NSString *)videoPath
                    onDisplays:(NSArray<NSNumber *> *)displayIDs {

  if (!videoPath || videoPath.length == 0) {
    NSLog(@"ERROR: Invalid videoPath");
    return;
  }

  self.currentVideoPath = videoPath;
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults setObject:videoPath forKey:@"LastWallpaperPath"];
  [defaults synchronize];

  const char *videoPathCStr = [videoPath UTF8String];
  std::string videoPathStr(videoPathCStr);
  std::filesystem::path p(videoPathStr);
  std::string videoName = p.stem().string();

  if (!fs::exists(videoPathStr)) {
    NSLog(@"Video file does not exist: %@", videoPath);
    return;
  }

  NSString *imageFilename =
      [NSString stringWithFormat:@"%s.png", videoName.c_str()];
  NSString *imagePath = [[self staticWallpaperCachePath]
      stringByAppendingPathComponent:imageFilename];

  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:imagePath] && !_generatingImages) {
    NSLog(@"Static wallpaper not found, generating for: %@", videoPath);
    [self generateStaticWallpapersForFolder:[self getFolderPath]
                             withCompletion:nil];
  }
  NSMutableArray<NSNumber *> *screensToUse = [displayIDs mutableCopy];
  if (screensToUse.count == 0) {
    screensToUse = [NSMutableArray array];
    for (const Display &display : displays) {
      [screensToUse addObject:@(display.screen)];
    }
  }

  for (NSNumber *displayNum in screensToUse) {
    CGDirectDisplayID displayID =
        (CGDirectDisplayID)[displayNum unsignedIntValue];
    [self launchDaemonOnScreen:videoPath
                     imagePath:imagePath
                     displayID:displayID];
  }
}

- (void)applyWallpaperToDisplay:(CGDirectDisplayID)displayID
                      videoPath:(NSString *)videoPath {
  NSLog(@"Applying wallpaper to display: %u with video: %@", displayID,
        videoPath);

  [self startWallpaperWithPath:videoPath onDisplays:@[ @(displayID) ]];
}

// ---------------------------------------------------------------------------
// launchd LaunchAgent management. The renderer's lifecycle is owned by launchd
// (KeepAlive), not by this app. We never posix_spawn or kill the daemon; we
// write a per-display plist and bootstrap/bootout it. See the redesign spec.
// ---------------------------------------------------------------------------

- (NSString *)launchAgentsDir {
  return [NSHomeDirectory()
      stringByAppendingPathComponent:@"Library/LaunchAgents"];
}

- (NSString *)agentLabelForUUID:(NSString *)uuid {
  return [@"com.thusvill.wallpaperdaemon." stringByAppendingString:uuid];
}

- (NSString *)agentPlistPathForUUID:(NSString *)uuid {
  return [[self launchAgentsDir]
      stringByAppendingPathComponent:
          [[self agentLabelForUUID:uuid] stringByAppendingString:@".plist"]];
}

- (NSString *)daemonBinaryPath {
  return [[[NSBundle mainBundle] bundlePath]
      stringByAppendingPathComponent:@"Contents/MacOS/wallpaperdaemon"];
}

- (NSString *)guiDomainTargetForUUID:(NSString *)uuid {
  return [NSString stringWithFormat:@"gui/%u/%@", getuid(),
                                    [self agentLabelForUUID:uuid]];
}

- (int)runLaunchctl:(NSArray<NSString *> *)args {
  NSTask *t = [[NSTask alloc] init];
  t.launchPath = @"/bin/launchctl";
  t.arguments = args;
  @try {
    [t launch];
    [t waitUntilExit];
    return t.terminationStatus;
  } @catch (NSException *e) {
    NSLog(@"launchctl %@ failed: %@", args, e);
    return -1;
  }
}

- (void)writeAgentPlistForUUID:(NSString *)uuid
                     videoPath:(NSString *)videoPath
                     imagePath:(NSString *)imagePath {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  float volume = [defaults floatForKey:@"wallpapervolume"];
  // scale mode is stored numerically; the daemon parses argv[4] with strtol.
  NSInteger scaleMode = [defaults integerForKey:@"scale_mode"];
  NSDictionary *plist = @{
    @"Label" : [self agentLabelForUUID:uuid],
    @"ProgramArguments" : @[
      [self daemonBinaryPath], videoPath, imagePath,
      [NSString stringWithFormat:@"%.2f", volume],
      [NSString stringWithFormat:@"%ld", (long)scaleMode], uuid
    ],
    // Crashed/kill -> restart; a deliberate non-zero exit (bad args) stays down.
    @"KeepAlive" : @{@"Crashed" : @YES, @"SuccessfulExit" : @NO},
    @"RunAtLoad" : @YES,
    @"ThrottleInterval" : @10,
    @"ProcessType" : @"Interactive",
    @"LimitLoadToSessionType" : @"Aqua",
  };
  [[NSFileManager defaultManager] createDirectoryAtPath:[self launchAgentsDir]
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  [plist writeToFile:[self agentPlistPathForUUID:uuid] atomically:YES];
}

// Force (re)install — used when the user picks/changes a wallpaper. bootout then
// bootstrap so launchd re-reads the plist (kickstart would keep the OLD argv).
- (void)installAgentForUUID:(NSString *)uuid
                  videoPath:(NSString *)videoPath
                  imagePath:(NSString *)imagePath {
  [self writeAgentPlistForUUID:uuid videoPath:videoPath imagePath:imagePath];
  [self runLaunchctl:@[ @"bootout", [self guiDomainTargetForUUID:uuid] ]];
  [self runLaunchctl:@[
    @"bootstrap", [NSString stringWithFormat:@"gui/%u", getuid()],
    [self agentPlistPathForUUID:uuid]
  ]];
  NSLog(@"Installed launchd agent for display %@", uuid);
}

// Install only if not already present — used on app launch so we don't restart
// (flicker) an agent launchd is already running via RunAtLoad. If an agent
// exists but points at a different daemon binary (the app was moved, e.g. a dev
// build promoted into /Applications), rewrite it so launchd re-execs the current
// bundle's daemon instead of a stale path.
- (void)ensureAgentForUUID:(NSString *)uuid
                 videoPath:(NSString *)videoPath
                 imagePath:(NSString *)imagePath {
  NSString *plistPath = [self agentPlistPathForUUID:uuid];
  if ([[NSFileManager defaultManager] fileExistsAtPath:plistPath]) {
    NSDictionary *existing =
        [NSDictionary dictionaryWithContentsOfFile:plistPath];
    NSString *program = [existing[@"ProgramArguments"] firstObject];
    if ([program isEqualToString:[self daemonBinaryPath]]) {
      return;
    }
    NSLog(@"Agent for %@ points at stale daemon %@; rewriting for current bundle",
          uuid, program);
  }
  [self installAgentForUUID:uuid videoPath:videoPath imagePath:imagePath];
}

- (void)bootoutAgentForUUID:(NSString *)uuid {
  [self runLaunchctl:@[ @"bootout", [self guiDomainTargetForUUID:uuid] ]];
  [[NSFileManager defaultManager]
      removeItemAtPath:[self agentPlistPathForUUID:uuid]
                 error:nil];
}

// Remove any wallpaperdaemon agents whose display UUID is not in liveUUIDs, so a
// disconnected display's agent can't fall back to and hijack the main screen.
- (void)reconcileAgentsWithLiveUUIDs:(NSSet<NSString *> *)liveUUIDs {
  NSArray<NSString *> *files =
      [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[self launchAgentsDir]
                                                          error:nil];
  NSString *prefix = @"com.thusvill.wallpaperdaemon.";
  for (NSString *f in files) {
    if (![f hasPrefix:prefix] || ![f hasSuffix:@".plist"]) continue;
    NSString *uuid = [[f substringFromIndex:prefix.length]
        stringByDeletingPathExtension];
    if (![liveUUIDs containsObject:uuid]) {
      NSLog(@"Reconcile: removing agent for absent display %@", uuid);
      [self bootoutAgentForUUID:uuid];
    }
  }
}

// One-shot migration off the old app-spawned model and stale login agents. Runs
// once; the recurring killall is gone (it would fight launchd's KeepAlive).
- (void)migrateLegacyLaunchState {
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  if ([d boolForKey:@"migratedToLaunchdV1"]) return;
  NSString *home = NSHomeDirectory();
  for (NSString *label in @[
         @"com.biosthusvill.LiveWallpaper", @"com.thusvill.LiveWallpaper"
       ]) {
    [self runLaunchctl:@[
      @"bootout", [NSString stringWithFormat:@"gui/%u/%@", getuid(), label]
    ]];
    [[NSFileManager defaultManager]
        removeItemAtPath:[home stringByAppendingPathComponent:
                                   [NSString stringWithFormat:
                                                 @"Library/LaunchAgents/%@.plist",
                                                 label]]
                   error:nil];
  }
  NSTask *t = [[NSTask alloc] init];
  t.launchPath = @"/usr/bin/killall";
  t.arguments = @[ @"wallpaperdaemon" ];
  @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) {
  }
  [d setBool:YES forKey:@"migratedToLaunchdV1"];
  NSLog(@"Migrated to launchd-managed wallpaper daemons");
}

- (void)launchDaemonOnScreen:(NSString *)videoPath
                   imagePath:(NSString *)imagePath
                   displayID:(CGDirectDisplayID)displayID {
  if (!displayID) {
    displayID = [[[NSScreen mainScreen] deviceDescription][@"NSScreenNumber"]
        unsignedIntValue];
  }
  std::string uuidStr = DisplayUUIDFromID(displayID);
  NSString *uuid = [NSString stringWithUTF8String:uuidStr.c_str()];
  // Persist selection (source of truth); pid 0 — launchd owns the process.
  SetWallpaperDisplay(0, displayID, std::string([videoPath UTF8String]),
                      std::string([imagePath UTF8String]));
  [self installAgentForUUID:uuid videoPath:videoPath imagePath:imagePath];
}

- (void)checkFolderPath {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if ([defaults objectForKey:@"WallpaperFolder"]) {
    folderPath = [defaults stringForKey:@"WallpaperFolder"];
  } else if (!folderPath) {
    folderPath = [NSHomeDirectory() stringByAppendingPathComponent:@"LiveWall"];
    [defaults setObject:folderPath forKey:@"WallpaperFolder"];
    [defaults synchronize];
  }
}

- (NSString *)getFolderPath {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSString *path = [defaults stringForKey:@"WallpaperFolder"];

  if (!path) {

    NSString *cacheDir =
        [[[NSFileManager defaultManager]
             URLsForDirectory:NSCachesDirectory
                    inDomains:NSUserDomainMask].firstObject path];

    path = [cacheDir stringByAppendingPathComponent:@"LiveWallpaper"];

    [defaults setObject:path forKey:@"WallpaperFolder"];
    [defaults synchronize];
  }

  return path;
}

- (void)checkWallpapers{
    if(_wallpaperList.count > 0){
        [_wallpaperList removeAllObjects];
    }
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    folderPath = [self getFolderPath];
    NSArray<NSString *> *allFiles =
        [fileManager contentsOfDirectoryAtPath:folderPath error:&error];

    if (error) {
      NSLog(@"Error reading directory: %@", error.localizedDescription);
        NSLog(@"Wallaper List returns Empty");
        return;
      
    }
    
    for (NSString *fileName in allFiles) {
      NSString *fileExtension = [[fileName pathExtension] lowercaseString];

      if ([fileExtension isEqualToString:@"mp4"] ||
          [fileExtension isEqualToString:@"mov"]) {
        NSString *fullPath = [folderPath stringByAppendingPathComponent:fileName];
        [_wallpaperList addObject:fullPath];
          NSLog(@"detected %@", fullPath);
      }
    }

    if (_wallpaperList.count == 0) {
        NSLog(@"Folder is empty, return zero for playlist");
        return;
    }
    
}

-(void) nextWallpaper{
    
    if(_rotationType == 1){
        if (_wallpaperList == nil || _wallpaperList.count == 0) {
                NSLog(@"⚠️ Cannot rotate: wallpaperList is empty.");
                [self stopWallpaperRotation];
                return;
            }
        
        _currentWallpaper = (_currentWallpaper + 1) % _wallpaperList.count;
        for (Display display : displays) {

          if (!display.videoPath.empty()) {
            CGDirectDisplayID displayID = DisplayIDFromUUID(display.uuid);

            [self startWallpaperWithPath:
             _wallpaperList[_currentWallpaper]
                              onDisplays:@[ @(displayID) ]];
          }
        }
        
    }else if(_rotationType == 2){
        [self randomWallpapersLid];
    }
}
- (void)stopWallpaperRotation {
    [self.wallpaperTimer invalidate];
    self.wallpaperTimer = nil;
    NSLog(@"Wallpaper rotation stoped.");
}
- (void)startWallpaperRotation{
    int delay = _rotationDelay;
    [self stopWallpaperRotation];
    [self checkWallpapers];
    
    if (_currentWallpaper >= _wallpaperList.count) {
            _currentWallpaper = 0;
        }

    self.wallpaperTimer = [NSTimer scheduledTimerWithTimeInterval:(NSTimeInterval)delay
                                                           target:self
                                                         selector:@selector(nextWallpaper)
                                                         userInfo:nil
                                                          repeats:YES];
    
    [self.wallpaperTimer fire];
    NSLog(@"Wallpaper rotation started with %d delay.", delay);
}

- (void)scanDisplays {
  ScanDisplays();
}

- (NSArray *)getDisplays {
  NSMutableArray *result = [NSMutableArray array];

  for (const Display &d : displays) {
    DisplayObjc *obj =
        [[DisplayObjc alloc] initWithDaemon:d.daemon
                                     screen:d.screen
                                       uuid:@(d.uuid.c_str())
                                  videoPath:@(d.videoPath.c_str())
                                  framePath:@(d.framePath.c_str())];

    [result addObject:obj];
  }

  return result;
}

- (void)selectFolder:(NSString *)path {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults setObject:path forKey:@"WallpaperFolder"];
}

- (void)terminateApplication {
  // Quitting the app must NOT stop the wallpaper — launchd keeps rendering it.
  SaveSystem::Save(displays);
  [self removeNotifications];
}

- (BOOL)isFirstLaunch {
  NSString *const kFirstLaunchKey = @"HasLaunchedOnce";
  if (![[NSUserDefaults standardUserDefaults] boolForKey:kFirstLaunchKey]) {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kFirstLaunchKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    return YES;
  }
  return NO;
}

-(void)updateVolume:(double)value{
    float f_percentage = value;
    float volume = f_percentage / 100.0f;

      NSLog(@"Slider: %.0f%% → volume: %.2f", f_percentage, volume);


      [[NSUserDefaults standardUserDefaults] setFloat:f_percentage
                                               forKey:@"wallpapervolumeprecentage"];
      [[NSUserDefaults standardUserDefaults] setFloat:volume
                                               forKey:@"wallpapervolume"];
      [[NSUserDefaults standardUserDefaults] synchronize];

      CFNotificationCenterPostNotification(
          CFNotificationCenterGetDarwinNotifyCenter(),
          CFSTR("com.live.wallpaper.volumeChanged"), NULL, NULL, true);
    }

-(void)updateScaleMode:(NSInteger)mode{
    
    [[NSUserDefaults standardUserDefaults] setObject:@(mode)
                                               forKey:@"scale_mode"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.live.wallpaper.scaleModeChanged"), NULL, NULL, true);
}


@end

CGImageRef CompressImageWithQuality(CGImageRef image, float qualityFactor) {
  NSBitmapImageRep *bitmapRep =
      [[NSBitmapImageRep alloc] initWithCGImage:image];

  NSData *compressedData =
      [bitmapRep representationUsingType:NSBitmapImageFileTypePNG
                              properties:@{
                                NSImageCompressionFactor : @(qualityFactor)
                              }];

  NSBitmapImageRep *compressedRep =
      [NSBitmapImageRep imageRepWithData:compressedData];
  return [compressedRep CGImage];
}


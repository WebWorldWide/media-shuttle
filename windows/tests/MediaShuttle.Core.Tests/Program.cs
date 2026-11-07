using MediaShuttle.Core;

namespace MediaShuttle.Core.Tests;

internal static class Program
{
    private static int _assertions;

    private static async Task<int> Main()
    {
        string testRoot = Path.Combine(Path.GetTempPath(), "MediaShuttle-Tests-" + Guid.NewGuid().ToString("N"));
        try
        {
            await RunAsync(testRoot);
            await RunParitySafetyAsync(testRoot);
            await RunCollisionReuseAsync(testRoot);
            Console.WriteLine($"PASS: {_assertions} assertions covering classification, settings, card arrivals, folder sources, verified copy, date folders, duplicates, collisions, collision reuse, links, cancellation, erase eligibility, and post-erase verification.");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine("FAIL: " + exception);
            return 1;
        }
        finally
        {
            if (Directory.Exists(testRoot))
            {
                ClearAttributes(testRoot);
                Directory.Delete(testRoot, true);
            }
        }
    }

    private static async Task RunAsync(string testRoot)
    {
        string cardRoot = Path.Combine(testRoot, "CARD");
        string destinationRoot = Path.Combine(testRoot, "Camera");
        string stateRoot = Path.Combine(testRoot, "State");
        Directory.CreateDirectory(Path.Combine(cardRoot, "DCIM", "100MSDCF"));
        Directory.CreateDirectory(Path.Combine(cardRoot, "PRIVATE", "M4ROOT", "CLIP"));
        Directory.CreateDirectory(destinationRoot);
        string stalePartial = Path.Combine(
            destinationRoot,
            "orphan.JPG.partial-0123456789abcdef0123456789abcdef");
        string unrelatedPartial = Path.Combine(destinationRoot, "keep.partial-draft");
        await File.WriteAllTextAsync(stalePartial, "stale interrupted transfer");
        await File.WriteAllTextAsync(unrelatedPartial, "user file");

        string jpeg = Path.Combine(cardRoot, "DCIM", "100MSDCF", "DSC00001.JPG");
        string raw = Path.Combine(cardRoot, "DCIM", "100MSDCF", "DSC00001.ARW");
        string appleDouble = Path.Combine(cardRoot, "DCIM", "100MSDCF", "._DSC00001.JPG");
        string video = Path.Combine(cardRoot, "PRIVATE", "M4ROOT", "CLIP", "C0001.MP4");
        await File.WriteAllTextAsync(jpeg, "jpeg-one");
        await File.WriteAllTextAsync(raw, "raw-one");
        await File.WriteAllTextAsync(appleDouble, "metadata-not-photo");
        await File.WriteAllTextAsync(video, "video-one");
        await File.WriteAllTextAsync(Path.Combine(cardRoot, "INDEX.XML"), "metadata");

        Assert(MediaClassifier.TryClassify(jpeg, out MediaKind jpegKind) && jpegKind == MediaKind.Jpeg, "JPEG classification");
        Assert(MediaClassifier.TryClassify(raw, out MediaKind rawKind) && rawKind == MediaKind.Raw, "RAW classification");
        Assert(MediaClassifier.TryClassify(video, out MediaKind videoKind) && videoKind == MediaKind.Video, "Video classification");
        Assert(!MediaClassifier.TryClassify(appleDouble, out _), "AppleDouble exclusion");
        foreach (string rawName in new[] { "IMG.CR3", "IMG.CR2", "DSC.NEF", "DSCF.RAF", "P.ORF", "P.RW2", "X.PEF", "X.X3F" })
        {
            Assert(
                MediaClassifier.TryClassify(rawName, out MediaKind kind) && kind == MediaKind.Raw,
                $"{Path.GetExtension(rawName)} is recognised as RAW");
        }
        Assert(
            MediaClassifier.TryClassify("A001.BRAW", out MediaKind brawKind) && brawKind == MediaKind.Video,
            ".braw is recognised as video");
        Assert(MediaClassifier.IsDisposableCameraArtifact("INDEX.XML"), "Camera metadata is disposable");
        Assert(MediaClassifier.IsDisposableCameraArtifact("GOPR0001.THM"), "Camera thumbnails are disposable");
        Assert(!MediaClassifier.IsDisposableCameraArtifact("NOTES.PDF"), "Unknown user content is not disposable");

        var stateStore = new StateStore(stateRoot);
        var logger = new AppLogger(stateRoot);
        var transfer = new TransferService(stateStore, logger);
        var wipe = new WipeService(stateStore, logger);
        var card = new CardInfo(cardRoot, "TEST CARD", 0, 64L * 1024 * 1024, 48L * 1024 * 1024, "Removable");

        string missingDestination = Path.Combine(testRoot, "Removed Camera");
        bool missingDestinationRejected = false;
        try
        {
            await transfer.TransferAsync(card, missingDestination, false, null, CancellationToken.None);
        }
        catch (DirectoryNotFoundException)
        {
            missingDestinationRejected = true;
        }
        Assert(missingDestinationRejected && !Directory.Exists(missingDestination),
            "Transfer does not recreate a missing destination");

        AppSettings newInstallSettings = await stateStore.LoadSettingsAsync();
        Assert(!newInstallSettings.AutoTransfer, "New installations leave automatic transfer off");
        Assert(newInstallSettings.ShowActivityLog, "New installations show the activity log by default");

        var mountedAtStartup = new CardPresenceTracker();
        Assert(
            !mountedAtStartup.Observe(cardRoot, [cardRoot]),
            "A card already mounted during the initial scan is baseline, not a new insertion");
        Assert(
            !mountedAtStartup.Observe(cardRoot, [cardRoot]),
            "A continuously mounted card is not reported as a new insertion");
        Assert(!mountedAtStartup.Observe(null, []), "Removing a card does not report an insertion");
        Assert(
            mountedAtStartup.Observe(cardRoot, [cardRoot]),
            "Reinserting a card after the initial scan is reported as a new insertion");

        string secondCardRoot = Path.Combine(testRoot, "SECOND-CARD");
        var multipleMountedAtStartup = new CardPresenceTracker();
        Assert(
            !multipleMountedAtStartup.Observe(cardRoot, [cardRoot, secondCardRoot]),
            "Every card present during the initial scan is added to the startup baseline");
        Assert(
            !multipleMountedAtStartup.Observe(secondCardRoot, [secondCardRoot]),
            "A second startup-mounted card is not reported as new when it becomes selected");

        var emptyAtStartup = new CardPresenceTracker();
        Assert(!emptyAtStartup.Observe(null, []), "An empty initial scan establishes the card baseline");
        Assert(
            emptyAtStartup.Observe(cardRoot, [cardRoot]),
            "A card first seen after an empty initial scan is reported as a new insertion");

        await stateStore.SaveSettingsAsync(new AppSettings
        {
            DestinationRoot = destinationRoot,
            AutoTransfer = true,
            Theme = "Dark",
            ShowActivityLog = false
        });
        AppSettings roundTripSettings = await stateStore.LoadSettingsAsync();
        Assert(roundTripSettings.DestinationRoot == destinationRoot, "Destination setting round trip");
        Assert(roundTripSettings.Theme == "Dark", "Theme setting round trip");
        Assert(roundTripSettings.AutoTransfer, "Automatic transfer opt-in round trip");
        Assert(!roundTripSettings.ShowActivityLog, "Activity log opt-out round trip");

        TransferResult first = await transfer.TransferAsync(card, destinationRoot, false, null, CancellationToken.None);
        Assert(first.Session.Status == "Verified", "Transfer reaches verified state");
        Assert(
            first.SessionFilePath == stateStore.SessionFilePath(first.Session),
            "Saved session path matches the deterministic report path");
        Assert(File.Exists(first.SessionFilePath), "Session report file exists after a verified transfer");
        Assert(first.Session.CopiedCount == 3, "Three genuine media files copied");
        Assert(first.Session.SkippedCount == 0, "No first-run duplicates");
        Assert(File.Exists(Path.Combine(destinationRoot, "Photos", "JPEGs", "DSC00001.JPG")), "JPEG destination");
        Assert(File.Exists(Path.Combine(destinationRoot, "Photos", "RAWs", "DSC00001.ARW")), "RAW destination");
        Assert(File.Exists(Path.Combine(destinationRoot, "Videos", "C0001.MP4")), "Video destination");
        Assert(
            !Directory.Exists(Path.Combine(destinationRoot, "Photos", "Other")),
            "No folder is created for a category the card has no files in");
        Assert(!File.Exists(stalePartial), "Stale Media Shuttle partial is cleaned up");
        Assert(File.Exists(unrelatedPartial), "Unrelated partial-like filename is preserved");

        TransferResult duplicate = await transfer.TransferAsync(card, destinationRoot, false, null, CancellationToken.None);
        Assert(duplicate.Session.CopiedCount == 0, "Duplicate rerun copies nothing");
        Assert(duplicate.Session.SkippedCount == 3, "Duplicate rerun verifies every file");

        await File.WriteAllTextAsync(jpeg, "jpeg-two");
        TransferResult collision = await transfer.TransferAsync(card, destinationRoot, false, null, CancellationToken.None);
        Assert(collision.Session.CopiedCount == 1, "Changed same-name file is copied");
        Assert(File.Exists(Path.Combine(destinationRoot, "Photos", "JPEGs", "DSC00001 (2).JPG")), "Collision uses numbered filename");
        TransferResult collisionRerun = await transfer.TransferAsync(card, destinationRoot, false, null, CancellationToken.None);
        Assert(collisionRerun.Session.CopiedCount == 0, "Rerun after a collision copies nothing");
        Assert(!File.Exists(Path.Combine(destinationRoot, "Photos", "JPEGs", "DSC00001 (3).JPG")), "Rerun reuses the numbered copy");
        Assert(
            collisionRerun.Session.Files.Any(record => record.DestinationPath.EndsWith("DSC00001 (2).JPG", StringComparison.Ordinal)),
            "Rerun records the numbered copy");

        // The same rule the other way round: a category the card does hold is still created.
        string otherCardRoot = Path.Combine(testRoot, "OTHER-CARD");
        string otherDestination = Path.Combine(testRoot, "Camera-Other");
        Directory.CreateDirectory(otherDestination);
        Directory.CreateDirectory(Path.Combine(otherCardRoot, "DCIM", "100MSDCF"));
        await File.WriteAllTextAsync(Path.Combine(otherCardRoot, "DCIM", "100MSDCF", "DSC00002.HEIC"), "heic-one");
        var otherCard = new CardInfo(otherCardRoot, "OTHER CARD", 0, 64L * 1024 * 1024, 48L * 1024 * 1024, "Removable");
        await transfer.TransferAsync(otherCard, otherDestination, false, null, CancellationToken.None);
        Assert(
            File.Exists(Path.Combine(otherDestination, "Photos", "Other", "DSC00002.HEIC")),
            "A card holding other-format photos still gets the Other folder");
        Assert(
            !Directory.Exists(Path.Combine(otherDestination, "Videos")),
            "A card holding no video leaves no empty Videos folder");

        string unverified = Path.Combine(cardRoot, "DCIM", "100MSDCF", "DSC99999.JPG");
        await File.WriteAllTextAsync(unverified, "not transferred");
        bool blocked = false;
        try
        {
            await wipe.WipeEverythingAsync(card, collision.Session, null, CancellationToken.None);
        }
        catch (InvalidOperationException exception) when (exception.Message.Contains("not part of the verified transfer"))
        {
            blocked = true;
        }
        Assert(blocked, "Erase blocks unverified media");
        File.Delete(unverified);

        // A format the classifier does not know is never copied, so erase has nothing to verify it
        // against and must refuse the whole card rather than delete it.
        string unknownFormat = Path.Combine(cardRoot, "DCIM", "100MSDCF", "CLIP0001.XYZ");
        await File.WriteAllTextAsync(unknownFormat, "an unrecognised camera format");
        Assert(
            MediaClassifier.FindUnverifiableFiles(cardRoot).Count == 1,
            "Unrecognised user content is reported as unverifiable");
        bool blockedUnknown = false;
        try
        {
            await wipe.WipeEverythingAsync(card, collision.Session, null, CancellationToken.None);
        }
        catch (InvalidOperationException exception) when (exception.Message.Contains("not recognised camera media"))
        {
            blockedUnknown = true;
        }
        Assert(blockedUnknown, "Erase blocks files it could never have copied");
        Assert(File.Exists(unknownFormat), "A blocked erase leaves unrecognised content untouched");
        File.Delete(unknownFormat);
        Assert(
            MediaClassifier.FindUnverifiableFiles(cardRoot).Count == 0,
            "Camera housekeeping alone does not block erase");

        File.SetAttributes(jpeg, File.GetAttributes(jpeg) | FileAttributes.ReadOnly);
        string readOnlyUnknown = Path.Combine(cardRoot, "CAMERA.DAT");
        await File.WriteAllTextAsync(readOnlyUnknown, "camera database");
        File.SetAttributes(readOnlyUnknown, FileAttributes.ReadOnly | FileAttributes.Hidden);

        string protectedCameraFolder = Path.Combine(cardRoot, "PRIVATE", "CAMERA_DB", "NESTED");
        Directory.CreateDirectory(protectedCameraFolder);
        string protectedCameraFile = Path.Combine(protectedCameraFolder, "INDEX.BDM");
        await File.WriteAllTextAsync(protectedCameraFile, "nested camera database");
        File.SetAttributes(protectedCameraFile, FileAttributes.ReadOnly | FileAttributes.Hidden);
        File.SetAttributes(Path.GetDirectoryName(protectedCameraFolder)!, FileAttributes.ReadOnly | FileAttributes.Hidden);
        string protectedDirectory = Path.Combine(cardRoot, "System Volume Information");
        Directory.CreateDirectory(protectedDirectory);

        WipeResult wipeResult = await wipe.WipeEverythingAsync(card, collision.Session, null, CancellationToken.None);
        Assert(wipeResult.DeletedFiles >= 5, "Erase deletes media and non-media files");
        string[] remaining = Directory.GetFileSystemEntries(cardRoot);
        Assert(remaining.Length == 1 && Path.GetFileName(remaining[0]) == "System Volume Information", "Only Windows-managed volume folder remains");
        Assert(MediaClassifier.Scan(cardRoot).Count == 0, "Post-erase media scan is empty");
        Assert(await stateStore.LoadLatestVerifiedForCardAsync(card) is null, "Erased session keeps older transfers locked");
    }

    private static async Task RunParitySafetyAsync(string testRoot)
    {
        string source = Path.Combine(testRoot, "MANUAL-SOURCE");
        string destination = Path.Combine(testRoot, "MANUAL-DESTINATION");
        Directory.CreateDirectory(source);
        Directory.CreateDirectory(destination);
        string photo = Path.Combine(source, "IMG.JPG");
        await File.WriteAllTextAsync(photo, "selected-folder-photo");
        CardInfo card = CardDetector.GetSelectedSource(source);
        Assert(card.DriveType == "Selected folder", "Ordinary source folders are identified as folders");
        Assert(!CardDetector.IsCameraCardVolume(source), "Ordinary source folders are never erasable cards");
        Assert(!CardDetector.IsCameraCardVolume(Path.GetPathRoot(Environment.SystemDirectory)!),
            "System volume is never an erasable camera card");
        var store = new StateStore(Path.Combine(testRoot, "PARITY-STATE"));
        var logger = new AppLogger(store.RootPath);
        var transfer = new TransferService(store, logger);
        var wipe = new WipeService(store, logger);
        await ExpectBlockedAsync(() => transfer.TransferAsync(card, source, false, null, CancellationToken.None),
            "Transfer rejects a destination equal to the source");
        string nestedDestination = Path.Combine(source, "BACKUP");
        await ExpectBlockedAsync(() => transfer.TransferAsync(card, nestedDestination, false, null, CancellationToken.None),
            "Transfer rejects a destination inside the source");
        Assert(!Directory.Exists(nestedDestination), "Unsafe destination is rejected before creating files");
        var updates = new List<OperationProgress>();
        TransferResult copied = await transfer.TransferAsync(card, destination, true,
            new InlineProgress(updates.Add), CancellationToken.None);
        Assert(copied.Session.CopiedCount == 1, "Selected folders transfer without a camera layout");
        string date = File.GetLastWriteTimeUtc(photo).ToLocalTime().ToString("yyyy-MM-dd");
        string destinationPhoto = Path.Combine(destination, "Photos", "JPEGs", date, "IMG.JPG");
        Assert(File.Exists(destinationPhoto), "Date grouping uses the source modification date");
        Assert(updates.Where(update => update.CurrentSourcePath.Length > 0)
            .All(update => update.CurrentDestinationFolder == Path.Combine("Photos", "JPEGs", date)),
            "Progress labels include the actual date folder");
        Assert(copied.Session.IsEligibleForErase(card, MediaClassifier.Scan(source)),
            "Unchanged source and destination match the saved transfer");
        Assert(!copied.Session.IsEligibleForErase(card with { VolumeSerial = card.VolumeSerial ^ 1 }, MediaClassifier.Scan(source)),
            "A different volume identity invalidates erase eligibility");
        copied.Session.Files.Add(copied.Session.Files[0]);
        Assert(!copied.Session.IsEligibleForErase(card, MediaClassifier.Scan(source)),
            "Duplicate source records invalidate erase eligibility");
        copied.Session.Files.RemoveAt(1);
        await ExpectBlockedAsync(() => wipe.WipeEverythingAsync(card, copied.Session, null, CancellationToken.None),
            "Core erase refuses a manually selected folder after a verified transfer");
        Assert(File.Exists(photo), "Selected-folder erase refusal preserves original media");

        CardInfo testCard = card with { DriveType = "Removable" };
        File.Move(photo, photo + ".held");
        try
        {
            Assert(!copied.Session.IsEligibleForErase(card, []), "An empty source invalidates the saved transfer");
            await ExpectBlockedAsync(() => wipe.WipeEverythingAsync(testCard, copied.Session, null, CancellationToken.None),
                "Core erase blocks a card whose verified media has been removed");
        }
        finally { File.Move(photo + ".held", photo); }
        await File.WriteAllTextAsync(photo, "resized-source");
        Assert(!copied.Session.IsEligibleForErase(card, MediaClassifier.Scan(source)),
            "Changed source size locks erase eligibility");
        await File.WriteAllTextAsync(photo, "selected-folder-photo");
        await File.WriteAllTextAsync(destinationPhoto, "tampered-destination");
        Assert(!copied.Session.IsEligibleForErase(card, MediaClassifier.Scan(source)),
            "Changed backup size locks erase eligibility");
        bool rejectedTamper = false;
        try { await wipe.WipeEverythingAsync(testCard, copied.Session, null, CancellationToken.None); }
        catch (IOException) { rejectedTamper = true; }
        Assert(rejectedTamper && File.Exists(photo), "Altered destination blocks erase and preserves the card");
        File.Delete(destinationPhoto);
        Assert(!copied.Session.IsEligibleForErase(card, MediaClassifier.Scan(source)),
            "Missing backup locks erase eligibility");
        bool rejectedMissing = false;
        try { await wipe.WipeEverythingAsync(testCard, copied.Session, null, CancellationToken.None); }
        catch (FileNotFoundException) { rejectedMissing = true; }
        Assert(rejectedMissing && File.Exists(photo), "Missing destination blocks erase and preserves the card");

        string nestedExcluded = Path.Combine(source, "NESTED", "System Volume Information");
        Directory.CreateDirectory(nestedExcluded);
        await File.WriteAllTextAsync(Path.Combine(nestedExcluded, "NOTES.PDF"), "user-content");
        Assert(MediaClassifier.ScanCard(source).UnverifiableFiles.Count == 1,
            "System-named folders nested in user content cannot hide unverified files");
        File.Delete(Path.Combine(nestedExcluded, "NOTES.PDF"));

        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        bool rejectedCancellation = false;
        try { await transfer.TransferAsync(card, destination, false, null, cancelled.Token); }
        catch (OperationCanceledException) { rejectedCancellation = true; }
        Assert(rejectedCancellation && File.Exists(photo), "Cancelled transfers preserve the source");
        Assert(!Directory.EnumerateFiles(destination, "*.partial-*", SearchOption.AllDirectories).Any(),
            "Cancelled transfers leave no partial copies");

        string linkedDestination = Path.Combine(testRoot, "LINKED-DESTINATION");
        CreateJunction(linkedDestination, source);
        try
        {
            await ExpectBlockedAsync(() => transfer.TransferAsync(card, linkedDestination, false, null, CancellationToken.None),
                "Transfer rejects a destination junction pointing to the source");
        }
        finally { Directory.Delete(linkedDestination); }

        string linkedCategory = Path.Combine(destination, "Photos", "RAWs");
        CreateJunction(linkedCategory, source);
        try
        {
            await File.WriteAllTextAsync(Path.Combine(source, "IMG.ARW"), "raw-photo");
            await ExpectBlockedAsync(() => transfer.TransferAsync(card, destination, false, null, CancellationToken.None),
                "Transfer rejects a category junction pointing to the source");
            Assert(!File.Exists(Path.Combine(source, "IMG (2).ARW")), "Rejected category junction creates no source collisions");
        }
        finally { Directory.Delete(linkedCategory); }
    }

    private sealed class InlineProgress(Action<OperationProgress> report) : IProgress<OperationProgress>
    {
        public void Report(OperationProgress value) => report(value);
    }

    private static async Task ExpectBlockedAsync(Func<Task> action, string message)
    {
        bool blocked = false;
        try { await action(); }
        catch (InvalidOperationException) { blocked = true; }
        Assert(blocked, message);
    }

    private static void CreateJunction(string link, string target)
    {
        using var process = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(
            "cmd.exe", $"/c mklink /J \"{link}\" \"{target}\"")
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true
        })!;
        process.WaitForExit();
        if (process.ExitCode != 0) throw new IOException("Could not create test junction: " + process.StandardError.ReadToEnd());
    }

    private static async Task RunCollisionReuseAsync(string testRoot)
    {
        string cardRoot = Path.Combine(testRoot, "REUSE-CARD");
        string destinationRoot = Path.Combine(testRoot, "Camera-Reuse");
        string stateRoot = Path.Combine(testRoot, "State-Reuse");
        string photo = Path.Combine(cardRoot, "DCIM", "100MSDCF", "DSC00010.JPG");
        Directory.CreateDirectory(Path.GetDirectoryName(photo)!);
        Directory.CreateDirectory(destinationRoot);
        await File.WriteAllTextAsync(photo, "first");
        var stateStore = new StateStore(stateRoot);
        var transfer = new TransferService(stateStore, new AppLogger(stateRoot));
        var card = new CardInfo(cardRoot, "REUSE", 0, 64L * 1024 * 1024, 48L * 1024 * 1024, "Removable");
        string jpegs = Path.Combine(destinationRoot, "Photos", "JPEGs");

        await transfer.TransferAsync(card, destinationRoot, false, null, CancellationToken.None);
        await File.WriteAllTextAsync(photo, "a longer second file");
        TransferResult collision = await transfer.TransferAsync(card, destinationRoot, false, null, CancellationToken.None);
        Assert(collision.Session.CopiedCount == 1, "Different-size same-name file is copied");
        Assert(File.Exists(Path.Combine(jpegs, "DSC00010 (2).JPG")), "Different-size collision uses numbered filename");

        TransferResult rerun = await transfer.TransferAsync(card, destinationRoot, false, null, CancellationToken.None);
        Assert(rerun.Session.CopiedCount == 0 && rerun.Session.SkippedCount == 1, "Different-size rerun reuses the numbered copy");
        Assert(!File.Exists(Path.Combine(jpegs, "DSC00010 (3).JPG")), "Different-size rerun writes no third copy");
        Assert(
            rerun.Session.Files.Single().DestinationPath.EndsWith("DSC00010 (2).JPG", StringComparison.Ordinal),
            "Different-size rerun records the numbered copy");
    }

    private static void Assert(bool condition, string message)
    {
        _assertions++;
        if (!condition)
        {
            throw new InvalidOperationException("Assertion failed: " + message);
        }
    }

    private static void ClearAttributes(string root)
    {
        foreach (string path in Directory.EnumerateFileSystemEntries(root, "*", SearchOption.AllDirectories).Reverse())
        {
            try
            {
                File.SetAttributes(path, FileAttributes.Normal);
            }
            catch
            {
            }
        }
    }
}

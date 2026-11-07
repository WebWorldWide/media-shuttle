using System.Security.Cryptography;

namespace MediaShuttle.Core;

public sealed class TransferService
{
    private const int BufferSize = 1024 * 1024;
    private const string PartialMarker = ".partial-";
    private readonly StateStore _stateStore;
    private readonly AppLogger _logger;

    public TransferService(StateStore stateStore, AppLogger logger)
    {
        _stateStore = stateStore;
        _logger = logger;
    }

    public async Task<TransferResult> TransferAsync(
        CardInfo card,
        string destinationRoot,
        bool groupByDate,
        IProgress<OperationProgress>? progress,
        CancellationToken cancellationToken)
    {
        destinationRoot = Path.GetFullPath(destinationRoot);
        PathUtilities.EnsureDestinationOutsideSource(destinationRoot, card.RootPath);
        if (!Directory.Exists(destinationRoot))
        {
            throw new DirectoryNotFoundException($"Destination is missing: {destinationRoot}");
        }
        CleanupPartials(destinationRoot);

        progress?.Report(new OperationProgress(OperationPhase.Scanning, "Scanning card", 0, 0, 0, 0));
        await _logger.WriteAsync($"Scanning {card.RootPath} for camera media", cancellationToken);
        IReadOnlyList<MediaItem> media = await Task.Run(
            () => MediaClassifier.Scan(card.RootPath),
            cancellationToken).ConfigureAwait(false);
        if (media.Count == 0)
        {
            throw new InvalidOperationException("No supported photos or videos were found on this card.");
        }

        long totalBytes = media.Sum(item => item.Size);
        EnsureFreeSpace(destinationRoot, BytesToWrite(destinationRoot, media, groupByDate));
        EnsureDestinationFolders(destinationRoot, media);

        var session = new TransferSession
        {
            StartedUtc = DateTimeOffset.UtcNow,
            SourceRoot = card.RootPath,
            SourceLabel = card.VolumeLabel,
            SourceVolumeSerial = card.VolumeSerial,
            DestinationRoot = destinationRoot,
            TotalFiles = media.Count,
            TotalBytes = totalBytes
        };

        long processedBytes = 0;
        int completedFiles = 0;
        foreach (MediaItem item in media)
        {
            cancellationToken.ThrowIfCancellationRequested();
            string folder = FolderFor(destinationRoot, item, groupByDate);
            PathUtilities.EnsureNoLinks(folder);
            Directory.CreateDirectory(folder);

            string destinationPath = Path.Combine(folder, item.FileName);
            PathUtilities.EnsureNoLinks(destinationPath);
            string hash;
            bool skipped = false;
            if (File.Exists(destinationPath) && new FileInfo(destinationPath).Length == item.Size)
            {
                progress?.Report(new OperationProgress(
                    OperationPhase.CheckingDuplicate,
                    item.FileName,
                    completedFiles,
                    media.Count,
                    processedBytes,
                    totalBytes,
                    session.CopiedCount,
                    session.SkippedCount,
                    item.SourcePath,
                    PathUtilities.RelativeDestinationFolder(session.DestinationRoot, destinationPath)));
                string sourceHash = await FileHasher.Sha256Async(item.SourcePath, cancellationToken).ConfigureAwait(false);
                string destinationHash = await FileHasher.Sha256Async(destinationPath, cancellationToken).ConfigureAwait(false);
                if (sourceHash.Equals(destinationHash, StringComparison.OrdinalIgnoreCase))
                {
                    hash = sourceHash;
                    skipped = true;
                    session.SkippedCount++;
                    processedBytes += item.Size;
                    await _logger.WriteAsync($"Verified existing {item.FileName}", cancellationToken);
                }
                else if (await FindNumberedCopyAsync(folder, item, sourceHash, cancellationToken).ConfigureAwait(false)
                         is (string numberedCopy, _))
                {
                    destinationPath = numberedCopy;
                    hash = sourceHash;
                    skipped = true;
                    session.SkippedCount++;
                    processedBytes += item.Size;
                    await _logger.WriteAsync($"Verified existing {Path.GetFileName(numberedCopy)}", cancellationToken);
                }
                else
                {
                    destinationPath = GetUniquePath(folder, item.FileName);
                    hash = await CopyAndVerifyAsync(
                        item,
                        destinationPath,
                        media.Count,
                        completedFiles,
                        totalBytes,
                        () => processedBytes,
                        value => processedBytes = value,
                        session,
                        progress,
                        cancellationToken).ConfigureAwait(false);
                }
            }
            else if (File.Exists(destinationPath) &&
                     await FindNumberedCopyAsync(folder, item, null, cancellationToken).ConfigureAwait(false)
                         is (string numberedCopy, string numberedHash))
            {
                destinationPath = numberedCopy;
                hash = numberedHash;
                skipped = true;
                session.SkippedCount++;
                processedBytes += item.Size;
                await _logger.WriteAsync($"Verified existing {Path.GetFileName(numberedCopy)}", cancellationToken);
            }
            else
            {
                if (File.Exists(destinationPath))
                {
                    destinationPath = GetUniquePath(folder, item.FileName);
                }
                hash = await CopyAndVerifyAsync(
                    item,
                    destinationPath,
                    media.Count,
                    completedFiles,
                    totalBytes,
                    () => processedBytes,
                    value => processedBytes = value,
                    session,
                    progress,
                    cancellationToken).ConfigureAwait(false);
            }

            if (!skipped)
            {
                session.CopiedCount++;
            }
            completedFiles++;
            progress?.Report(new OperationProgress(
                OperationPhase.Verifying,
                item.FileName,
                completedFiles,
                media.Count,
                processedBytes,
                totalBytes,
                session.CopiedCount,
                session.SkippedCount,
                item.SourcePath,
                PathUtilities.RelativeDestinationFolder(session.DestinationRoot, destinationPath)));
            session.Files.Add(new TransferRecord
            {
                SourcePath = item.SourcePath,
                DestinationPath = destinationPath,
                Sha256 = hash,
                Size = item.Size,
                Kind = item.Kind
            });
        }

        session.Status = "Verified";
        session.CompletedUtc = DateTimeOffset.UtcNow;
        string sessionFilePath = await _stateStore.SaveSessionAsync(session, cancellationToken).ConfigureAwait(false);
        await _logger.WriteAsync(
            $"Transfer verified: {session.CopiedCount} copied, {session.SkippedCount} already safe",
            cancellationToken).ConfigureAwait(false);
        progress?.Report(new OperationProgress(
            OperationPhase.Complete,
            "Transfer verified",
            media.Count,
            media.Count,
            totalBytes,
            totalBytes,
            session.CopiedCount,
            session.SkippedCount));
        return new TransferResult(session, sessionFilePath);
    }

    private async Task<string> CopyAndVerifyAsync(
        MediaItem item,
        string destinationPath,
        int totalFiles,
        int completedFiles,
        long totalBytes,
        Func<long> getProcessedBytes,
        Action<long> setProcessedBytes,
        TransferSession session,
        IProgress<OperationProgress>? progress,
        CancellationToken cancellationToken)
    {
        string temporaryPath = destinationPath + PartialMarker + Guid.NewGuid().ToString("N");
        long copiedBytes = 0;
        try
        {
            await _logger.WriteAsync($"Copying {item.FileName}", cancellationToken);
            using IncrementalHash sourceHasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            await using (var source = new FileStream(
                             item.SourcePath,
                             FileMode.Open,
                             FileAccess.Read,
                             FileShare.Read,
                             BufferSize,
                             FileOptions.Asynchronous | FileOptions.SequentialScan))
            await using (var destination = new FileStream(
                             temporaryPath,
                             FileMode.CreateNew,
                             FileAccess.Write,
                             FileShare.None,
                             BufferSize,
                             FileOptions.Asynchronous | FileOptions.SequentialScan))
            {
                byte[] buffer = new byte[BufferSize];
                int read;
                while ((read = await source.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) > 0)
                {
                    copiedBytes += read;
                    sourceHasher.AppendData(buffer, 0, read);
                    await destination.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
                    long next = getProcessedBytes() + read;
                    setProcessedBytes(next);
                    progress?.Report(new OperationProgress(
                        OperationPhase.Copying,
                        item.FileName,
                        completedFiles,
                        totalFiles,
                        next,
                        totalBytes,
                        session.CopiedCount,
                        session.SkippedCount,
                        item.SourcePath,
                        PathUtilities.RelativeDestinationFolder(session.DestinationRoot, destinationPath)));
                }
                await destination.FlushAsync(cancellationToken).ConfigureAwait(false);
            }

            // Both hashes are taken from the bytes that were actually copied, so a file the camera
            // was still writing when the scan sized it passes verification and is then recorded
            // against the stale size. Erase compares the destination against that recorded size and
            // refuses the card — permanently, and with no explanation the card can act on. Catch the
            // change here instead, while re-scanning and transferring again still fixes it.
            if (copiedBytes != item.Size)
            {
                throw new IOException(
                    $"{item.FileName} changed while it was being copied. Re-scan the card and transfer again.");
            }

            string sourceHash = Convert.ToHexString(sourceHasher.GetHashAndReset());
            File.SetLastWriteTimeUtc(temporaryPath, item.LastWriteTimeUtc);
            progress?.Report(new OperationProgress(
                OperationPhase.Verifying,
                item.FileName,
                completedFiles,
                totalFiles,
                getProcessedBytes(),
                totalBytes,
                session.CopiedCount,
                session.SkippedCount,
                item.SourcePath,
                PathUtilities.RelativeDestinationFolder(session.DestinationRoot, destinationPath)));
            string destinationHash = await FileHasher.Sha256Async(temporaryPath, cancellationToken).ConfigureAwait(false);
            if (!sourceHash.Equals(destinationHash, StringComparison.OrdinalIgnoreCase))
            {
                throw new IOException($"SHA-256 verification failed for {item.FileName}.");
            }
            File.Move(temporaryPath, destinationPath);
            await _logger.WriteAsync($"Verified {item.FileName}", cancellationToken);
            return sourceHash;
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.SetAttributes(temporaryPath, FileAttributes.Normal);
                File.Delete(temporaryPath);
            }
        }
    }

    private static string FolderFor(string destinationRoot, MediaItem item, bool groupByDate)
    {
        string folder = Path.Combine(destinationRoot, MediaClassifier.DestinationFolder(item.Kind));
        return groupByDate
            ? Path.Combine(folder, item.LastWriteTimeUtc.ToLocalTime().ToString("yyyy-MM-dd"))
            : folder;
    }

    private static string NumberedPath(string directory, string fileName, int number) =>
        Path.Combine(
            directory,
            $"{Path.GetFileNameWithoutExtension(fileName)} ({number}){Path.GetExtension(fileName)}");

    private static string GetUniquePath(string directory, string fileName)
    {
        for (int number = 2; ; number++)
        {
            string candidate = NumberedPath(directory, fileName, number);
            if (!File.Exists(candidate) && !Directory.Exists(candidate))
            {
                return candidate;
            }
        }
    }

    private static long ExistingFileSize(string path)
    {
        try
        {
            var info = new FileInfo(path);
            return info.Exists && !info.Attributes.HasFlag(FileAttributes.ReparsePoint) ? info.Length : -1;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return -1;
        }
    }

    /// <summary>
    /// A different file that once had this name was kept as "NAME (2).EXT", and the copy of this
    /// file may be one of those numbered names. Without looking, every repeat transfer of the card
    /// wrote another "(3)", "(4)" copy of the same file.
    /// </summary>
    private static async Task<(string Path, string Sha256)?> FindNumberedCopyAsync(
        string folder,
        MediaItem item,
        string? sourceHash,
        CancellationToken cancellationToken)
    {
        var candidates = new List<string>();
        for (int number = 2; ; number++)
        {
            string candidate = NumberedPath(folder, item.FileName, number);
            if (!File.Exists(candidate) && !Directory.Exists(candidate))
            {
                break;
            }
            if (ExistingFileSize(candidate) == item.Size)
            {
                candidates.Add(candidate);
            }
        }
        if (candidates.Count == 0)
        {
            return null;
        }

        sourceHash ??= await FileHasher.Sha256Async(item.SourcePath, cancellationToken).ConfigureAwait(false);
        foreach (string candidate in candidates)
        {
            string candidateHash = await FileHasher.Sha256Async(candidate, cancellationToken).ConfigureAwait(false);
            if (candidateHash.Equals(sourceHash, StringComparison.OrdinalIgnoreCase))
            {
                return (candidate, sourceHash);
            }
        }
        return null;
    }

    /// <summary>
    /// Counts only what may have to be written. A same-size file already under its own name is
    /// almost always the copy an earlier run made, so counting it made "Transfer again" on a full
    /// card ask for the whole card's size in free space a second time with nothing left to copy.
    /// </summary>
    private static long BytesToWrite(string destinationRoot, IReadOnlyList<MediaItem> media, bool groupByDate) =>
        media
            .Where(item => ExistingFileSize(Path.Combine(FolderFor(destinationRoot, item, groupByDate), item.FileName)) != item.Size)
            .Sum(item => item.Size);

    /// <summary>
    /// Creates a category folder only for the kinds this card actually holds. Creating all four up
    /// front left an empty Photos\Other next to every transfer of a card with no other-format
    /// photos, which reads as a category that failed rather than one that was never needed.
    /// </summary>
    private static void EnsureDestinationFolders(string destinationRoot, IReadOnlyList<MediaItem> media)
    {
        foreach (MediaKind kind in media.Select(item => item.Kind).Distinct())
        {
            string folder = Path.Combine(destinationRoot, MediaClassifier.DestinationFolder(kind));
            PathUtilities.EnsureNoLinks(folder);
            Directory.CreateDirectory(folder);
        }
    }

    private static void CleanupPartials(string destinationRoot)
    {
        // IgnoreInaccessible: a single unreadable folder anywhere under the destination otherwise
        // throws out of the enumeration itself and fails the whole transfer before it starts.
        var options = new EnumerationOptions
        {
            RecurseSubdirectories = true,
            IgnoreInaccessible = true,
            AttributesToSkip = FileAttributes.ReparsePoint
        };
        foreach (string partial in Directory.EnumerateFiles(destinationRoot, $"*{PartialMarker}*", options))
        {
            if (!IsOwnedPartial(partial))
            {
                continue;
            }

            try
            {
                File.SetAttributes(partial, FileAttributes.Normal);
                File.Delete(partial);
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }

    private static bool IsOwnedPartial(string path)
    {
        string fileName = Path.GetFileName(path);
        int markerIndex = fileName.LastIndexOf(PartialMarker, StringComparison.OrdinalIgnoreCase);
        if (markerIndex < 0)
        {
            return false;
        }

        ReadOnlySpan<char> identifier = fileName.AsSpan(markerIndex + PartialMarker.Length);
        if (identifier.Length != 32)
        {
            return false;
        }

        foreach (char character in identifier)
        {
            if (!Uri.IsHexDigit(character))
            {
                return false;
            }
        }

        return true;
    }

    // DriveInfo answers for drive letters only: it rejects a UNC share and reports the host volume
    // rather than the mounted one for a directory mount point, so a network or mounted destination
    // failed the check with "Object must be a root directory" instead of being measured.
    private static void EnsureFreeSpace(string destinationRoot, long bytesToWrite)
    {
        ulong availableBytes;
        if (OperatingSystem.IsWindows())
        {
            if (!NativeMethods.GetDiskFreeSpaceEx(destinationRoot, out availableBytes, out _, out _))
            {
                throw new IOException("Couldn't read the free space on the destination drive.");
            }
        }
        else
        {
            // Only the core tests run off Windows.
            availableBytes = (ulong)Math.Max(0, new DriveInfo(destinationRoot).AvailableFreeSpace);
        }

        const ulong reserve = 1024UL * 1024UL * 1024UL;
        if (availableBytes < (ulong)Math.Max(0, bytesToWrite) + reserve)
        {
            throw new IOException(
                "Not enough free space at the destination. Free up room for the new files plus 1 GB, or choose another destination.");
        }
    }
}

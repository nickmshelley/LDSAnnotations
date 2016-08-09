//
// Copyright (c) 2016 Hilton Campbell
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//

import Foundation
import PSOperations

class SyncAnnotationsOperation: Operation {
    
    let session: Session
    let annotationStore: AnnotationStore
    let notebookAnnotationIDs: [String: [String]]
    let previousLocalSyncAnnotationsDate: NSDate?
    let previousServerSyncAnnotationsDate: NSDate?
    
    var localSyncAnnotationsDate: NSDate?
    var serverSyncAnnotationsDate: NSDate?

    var uploadAnnotationCount = 0
    var uploadHighlightCount = 0
    var uploadBookmarkCount = 0
    var uploadNoteCount = 0
    var uploadLinkCount = 0
    var uploadTagCount = 0
    
    var downloadAnnotationCount = 0
    var downloadHighlightCount = 0
    var downloadBookmarkCount = 0
    var downloadNoteCount = 0
    var downloadLinkCount = 0
    var downloadTagCount = 0
    var deserializationErrors = [NSError]()
    
    init(session: Session, annotationStore: AnnotationStore, notebookAnnotationIDs: [String: [String]], localSyncAnnotationsDate: NSDate?, serverSyncAnnotationsDate: NSDate?, completion: (SyncAnnotationsResult) -> Void) {
        self.session = session
        self.annotationStore = annotationStore
        self.notebookAnnotationIDs = notebookAnnotationIDs
        self.previousLocalSyncAnnotationsDate = localSyncAnnotationsDate
        self.previousServerSyncAnnotationsDate = serverSyncAnnotationsDate
        
        super.init()
        
        addCondition(AuthenticateCondition(session: session))
        addObserver(BlockObserver(startHandler: nil, produceHandler: nil, finishHandler: { operation, errors in
            if errors.isEmpty, let localSyncAnnotationsDate = self.localSyncAnnotationsDate, serverSyncAnnotationsDate = self.serverSyncAnnotationsDate {
                let changes = SyncAnnotationsChanges(uploadAnnotationCount: self.uploadAnnotationCount,
                    uploadNoteCount: self.uploadNoteCount,
                    uploadBookmarkCount: self.uploadBookmarkCount,
                    uploadHighlightCount: self.uploadHighlightCount,
                    uploadTagCount: self.uploadTagCount,
                    uploadLinkCount: self.uploadLinkCount,
                    downloadAnnotationCount: self.downloadAnnotationCount,
                    downloadNoteCount: self.downloadNoteCount,
                    downloadBookmarkCount: self.downloadBookmarkCount,
                    downloadHighlightCount: self.downloadHighlightCount,
                    downloadTagCount: self.downloadTagCount,
                    downloadLinkCount: self.downloadLinkCount)
                completion(.Success(localSyncAnnotationsDate: localSyncAnnotationsDate, serverSyncAnnotationsDate: serverSyncAnnotationsDate, changes: changes, deserializationErrors: self.deserializationErrors))
            } else {
                completion(.Error(errors: errors))
            }
        }))
    }
    
    override func execute() {
        let localSyncDate = NSDate()
        let localChanges = localChangesAfter(previousLocalSyncAnnotationsDate, onOrBefore: localSyncDate)
        
        self.localSyncAnnotationsDate = localSyncDate
        
        var syncAnnotations: [String: AnyObject] = [
            "since": (previousServerSyncAnnotationsDate ?? NSDate(timeIntervalSince1970: 0)).formattedISO8601,
            "clientTime": NSDate().formattedISO8601,
        ]
        
        if !localChanges.isEmpty {
            syncAnnotations["changes"] = localChanges
        }
        
        if previousServerSyncAnnotationsDate == nil {
            syncAnnotations["syncStatus"] = "notdeleted"
        }
        
        let payload = ["syncAnnotations": syncAnnotations]
        
        session.put("/ws/annotation/v1.4/Services/rest/sync/annotations-ids?xver=2", payload: payload) { response in
            switch response {
            case .Success(let payload):
                let errorsJSON = (payload[safe: "syncAnnotationsIds"] as? [String: AnyObject])?[safe: "errors"]
                if let errorsJSON = errorsJSON as? [[String: AnyObject]] where !errorsJSON.isEmpty {
                    // Server returned errors, fail
                    
                    let errors = errorsJSON.map { Error.errorWithCode(.SyncFailed, failureReason: String(format: "Failed to sync annotation with unique ID \"%@\": %@", $0[safe: "id"] as? String ?? "Unknown", $0[safe: "msg"] as? String ?? "Unknown")) }
                    self.finish(errors)
                    
                } else {
                    // No errors, sync is good
                    
                    do {
                        try self.requestVersionedAnnotations(payload, onOrBefore: localSyncDate)
                    } catch let error as NSError {
                        self.finishWithError(error)
                    }
                }
            case .Failure(let payload):
                self.finishWithError(Error.errorWithCode(.Unknown, failureReason: "Failure response: \(payload)"))
            case .Error(let error):
                self.finishWithError(error)
            }
        }
    }
    
    func localChangesAfter(after: NSDate?, onOrBefore: NSDate) -> [[String: AnyObject]] {
        let modifiedAnnotations = annotationStore.allAnnotations(lastModifiedAfter: after, lastModifiedOnOrBefore: onOrBefore)
        
        uploadAnnotationCount = modifiedAnnotations.count
        
        let localChanges = modifiedAnnotations.map { annotation -> [String: AnyObject] in
            var result: [String: AnyObject] = [
                "changeType": ChangeType(status: annotation.status).rawValue,
                "annotationId": annotation.uniqueID,
                "timestamp": annotation.lastModified.formattedISO8601,
            ]
            
            if annotation.status == .Active {
                result["annotation"] = annotation.jsonObject(annotationStore)
            }
            
            return result
        }
        
        for change in localChanges {
            guard let annotation = change["annotation"] as? [String: AnyObject] else { continue }
        
            uploadNoteCount += (annotation["note"] != nil) ? 1 : 0
            uploadBookmarkCount += (annotation["bookmark"] != nil) ? 1 : 0
            if let highlights = annotation["highlights"] as? [String: [[String: AnyObject]]], count = highlights["highlight"]?.count {
                uploadHighlightCount += count
            }
            if let links = annotation["references"] as? [String: [[String: AnyObject]]], count = links["reference"]?.count {
                uploadLinkCount += count
            }
            if let tags = annotation["tags"] as? [String: [[String: AnyObject]]], count = tags["tag"]?.count {
                uploadTagCount += count
            }
        }
        
        return localChanges
    }
    
    func requestVersionedAnnotations(payload: [String: AnyObject], onOrBefore: NSDate) throws {
        guard let syncAnnotations = payload["syncAnnotationsIds"] as? [String: AnyObject] else {
            throw Error.errorWithCode(.Unknown, failureReason: "Missing syncAnnotationsIds")
        }
        
        guard let rawServerSyncDate = syncAnnotations["before"] as? String, serverSyncDate = NSDate.parseFormattedISO8601(rawServerSyncDate) else {
            throw Error.errorWithCode(.Unknown, failureReason: "Missing before")
        }
        
        self.serverSyncAnnotationsDate = serverSyncDate
        
        guard let syncIDs = syncAnnotations["syncIds"] as? [[String: AnyObject]] else {
            throw Error.errorWithCode(.Unknown, failureReason: "Missing syncIds")
        }
                
        let docIDs = syncIDs.flatMap { $0["docId"] as? String }
        let docIDsAndVersions = session.docVersionsForDocIDs?(docIDs: docIDs)
        
        let annotationIDsAndVersions = syncIDs.flatMap { syncID -> [String: AnyObject]? in
            guard let annotationID = syncID["aid"] as? String else { return nil }
            
            if let docID = syncID["docId"] as? String, version = docIDsAndVersions?[docID] {
                return ["aid": annotationID, "ver": version]
            }
            return ["aid": annotationID]
        }
        
        executeVersionedAnnotationsRequest(annotationIDsAndVersions, onOrBefore: onOrBefore)
    }
    
    func executeVersionedAnnotationsRequest(annotationIDsAndVersions: [[String: AnyObject]], onOrBefore: NSDate) {
        let annotationVersions: [String: AnyObject] = [
            "clientTime": NSDate().formattedISO8601,
            "annoVers": annotationIDsAndVersions
        ]
        let payload = [
            "xformAnnoVers": annotationVersions
        ]
        
        session.put("/ws/annotation/v1.4/Services/rest/xform/annotations?xver=2", payload: payload) { response in
            switch response {
            case .Success(let payload):
                do {
                    try self.annotationStore.inSyncTransaction {
                        try self.applyServerChanges(payload, onOrBefore: onOrBefore)
                    }
                    self.finish()
                } catch let error as NSError {
                    self.finishWithError(error)
                }
            case .Failure(let payload):
                self.finishWithError(Error.errorWithCode(.Unknown, failureReason: "Failure response: \(payload)"))
            case .Error(let error):
                self.finishWithError(error)
            }
        }
    }
    
    func applyServerChanges(payload: [String: AnyObject], onOrBefore: NSDate) throws {
        guard let syncAnnotations = payload["syncAnnotations"] as? [String: AnyObject] else {
            throw Error.errorWithCode(.Unknown, failureReason: "Missing syncAnnotations")
        }
        
        if let remoteChanges = syncAnnotations["changes"] as? [[String: AnyObject]] {
            for change in remoteChanges {
                guard let rawChangeType = change["changeType"] as? String, changeType = ChangeType(rawValue: rawChangeType) else {
                    throw Error.errorWithCode(.Unknown, failureReason: "Missing changeType")
                }
                
                guard let uniqueID = change["annotationId"] as? String else {
                    throw Error.errorWithCode(.Unknown, failureReason: "Missing annotationId")
                }
                
                guard let rawAnnotation = change["annotation"] as? [String: AnyObject] else {
                    throw Error.errorWithCode(.Unknown, failureReason: "Missing annotation")
                }
                
                guard let rawLastModified = rawAnnotation["timestamp"] as? String, lastModified = NSDate.parseFormattedISO8601(rawLastModified) else {
                    throw Error.errorWithCode(.Unknown, failureReason: "Missing last modified date")
                }
                
                guard let source = rawAnnotation["source"] as? String else {
                    throw Error.errorWithCode(.Unknown, failureReason: "`source` is a required field, the service returned a nil value")
                }
                
                guard let device = rawAnnotation["device"] as? String else {
                    throw Error.errorWithCode(.Unknown, failureReason: "`device` is a required field, the service returned a nil value")
                }

                switch changeType {
                case .New:
                    let iso639_3Code = rawAnnotation["@locale"] as? String ?? "eng"
                    let docID = rawAnnotation["@docId"] as? String
                    let docVersion = (rawAnnotation["@contentVersion"] as? String).flatMap { Int($0) }
                    let created = (rawAnnotation["created"] as? String).flatMap { NSDate.parseFormattedISO8601($0) }
                    let status = (rawAnnotation["@status"] as? String).flatMap { AnnotationStatus(rawValue: $0) } ?? .Active
                    
                    do {
                        try annotationStore.db.savepoint {
                            let databaseAnnotation: Annotation?
                            if var existingAnnotation = self.annotationStore.annotationWithUniqueID(uniqueID) {
                                existingAnnotation.iso639_3Code = iso639_3Code
                                existingAnnotation.source = source
                                existingAnnotation.device = device
                                existingAnnotation.docID = docID
                                existingAnnotation.docVersion = docVersion
                                existingAnnotation.created = created
                                existingAnnotation.lastModified = lastModified
                                existingAnnotation.status = status
                                databaseAnnotation = try self.annotationStore.updateAnnotation(existingAnnotation, inSync: true)
                            } else {
                                databaseAnnotation = try self.annotationStore.addAnnotation(uniqueID: uniqueID, iso639_3Code: iso639_3Code, docID: docID, docVersion: docVersion, created: created, lastModified: lastModified, source: source, device: device, inSync: true)
                            }
                            self.downloadAnnotationCount += 1
                            
                            if let annotationID = databaseAnnotation?.id, annotationUniqueID = databaseAnnotation?.uniqueID {
                                
                                // MARK: Note
                                
                                if let note = rawAnnotation["note"] as? [String: AnyObject] {
                                    let title = note["title"] as? String
                                    let content = note["content"] as? String ?? ""
                                    if var existingNote = self.annotationStore.noteWithAnnotationID(annotationID) {
                                        existingNote.title = title
                                        existingNote.content = content
                                        try self.annotationStore.updateNote(existingNote)
                                    } else {
                                        try self.annotationStore.addNote(title: title, content: content, annotationID: annotationID)
                                    }
                                    self.downloadNoteCount += 1
                                } else if let noteID = self.annotationStore.noteWithAnnotationID(annotationID)?.id {
                                    // The service says that the note has been deleted
                                    
                                    try self.annotationStore.deleteNoteWithID(noteID)
                                }
                                
                                // MARK: Bookmark
                                
                                if let bookmark = rawAnnotation["bookmark"] as? [String: AnyObject] {
                                    if bookmark["@pid"] == nil && bookmark["uri"] != nil {
                                        // Bookmark has a URI, but no @pid so its invalid. If both are nil, its a valid chapter-level bookmark
                                        throw Error.errorWithCode(.InvalidParagraphAID, failureReason: "Failed to deserialize bookmark, missing PID: \(bookmark)")
                                    }
                                    
                                    let name = bookmark["name"] as? String
                                    let paragraphAID = bookmark["@pid"] as? String
                                    let displayOrder = bookmark["sort"] as? Int ?? .max
                                    let offset = bookmark["@offset"] as? Int ?? Bookmark.Offset
                                    
                                    if var databaseBookmark = self.annotationStore.bookmarkWithAnnotationID(annotationID) {
                                        databaseBookmark.name = name
                                        databaseBookmark.paragraphAID = paragraphAID
                                        databaseBookmark.displayOrder = displayOrder
                                        databaseBookmark.offset = offset
                                        
                                        try self.annotationStore.updateBookmark(databaseBookmark)
                                    } else {
                                        try self.annotationStore.addBookmark(name: name, paragraphAID: paragraphAID, displayOrder: displayOrder, annotationID: annotationID, offset: offset)
                                    }
                                    
                                    self.downloadBookmarkCount += 1
                                } else if let bookmarkID = self.annotationStore.bookmarkWithAnnotationID(annotationID)?.id {
                                    // The service says that the bookmark has been deleted
                                    
                                    try self.annotationStore.deleteBookmarkWithID(bookmarkID)
                                }
                                
                                // MARK: Notebooks
                                
                                var notebookIDsToDelete = self.annotationStore.notebooksWithAnnotationID(annotationID).flatMap { $0.id }
                                if let folders = rawAnnotation["folders"] as? [String: [[String: AnyObject]]] {
                                    for folder in folders["folder"] ?? [] {
                                        guard let notebookUniqueID = folder["@uri"]?.lastPathComponent else {
                                            throw Error.errorWithCode(.Unknown, failureReason: "Failed to deserialize notebook: \(folder)")
                                        }
                                        
                                        guard let notebookID = self.annotationStore.notebookWithUniqueID(notebookUniqueID)?.id else {
                                            throw Error.errorWithCode(.Unknown, failureReason: "Cannot find notebook with uniqueID \(notebookUniqueID)")
                                        }
                                        
                                        if let index = notebookIDsToDelete.indexOf(notebookID) {
                                            // This notebook is still connected to the annotation, so remove it from the list of notebook IDs to delete
                                            notebookIDsToDelete.removeAtIndex(index)
                                        }
                                        
                                        // Don't fail if we don't get a display order from the syncFolders, just put it at the end
                                        let displayOrder = self.notebookAnnotationIDs[notebookUniqueID]?.indexOf(annotationUniqueID) ?? .max
                                        
                                        try self.annotationStore.addOrUpdateAnnotationNotebook(annotationID: annotationID, notebookID: notebookID, displayOrder: displayOrder)
                                    }
                                }
                                for notebookID in notebookIDsToDelete {
                                    // Any notebook IDs left in `databaseNotebookIDs` should be deleted because the service says they aren't connected anymore
                                    try self.annotationStore.deleteAnnotation(annotationID: annotationID, fromNotebook: notebookID)
                                }
                                
                                // MARK: Highlights
                                
                                // Delete any existing highlights and then we'll just create new ones with what the server gives us
                                for highlightID in self.annotationStore.highlightsWithAnnotationID(annotationID).flatMap({ $0.id }) {
                                    try self.annotationStore.deleteHighlightWithID(highlightID)
                                }
                                
                                // Add new highlights
                                if let highlights = rawAnnotation["highlights"] as? [String: [[String: AnyObject]]] {
                                    for highlight in highlights["highlight"] ?? [] {
                                        guard let offsetStartString = highlight["@offset-start"] as? String, offsetStart = Int(offsetStartString), offsetEndString = highlight["@offset-end"] as? String, offsetEnd = Int(offsetEndString), colorName = highlight["@color"] as? String else {
                                            throw Error.errorWithCode(.InvalidHighlight, failureReason: "Failed to deserialize highlight: \(highlight)")
                                        }
                                        
                                        guard let paragraphAID = highlight["@pid"] as? String else {
                                            throw Error.errorWithCode(.InvalidParagraphAID, failureReason: "Failed to deserialize highlight, missing PID: \(highlight)")
                                        }
                                        
                                        let paragraphRange = ParagraphRange(paragraphAID: paragraphAID, startWordOffset: offsetStart, endWordOffset: offsetEnd)
                                        let style = (highlight["@style"] as? String).flatMap { HighlightStyle(rawValue: $0) } ?? .Highlight
                                        
                                        try self.annotationStore.addHighlight(paragraphRange: paragraphRange, colorName: colorName, style: style, annotationID: annotationID)
                                        self.downloadHighlightCount += 1
                                    }
                                }
                                
                                // MARK: Links
                                
                                // Delete any existing links and then we'll just create new ones with what the server gives us
                                for linkID in self.annotationStore.linksWithAnnotationID(annotationID).flatMap({ $0.id }) {
                                    // Any link IDs left in `linksIDsToDelete` should be deleted because the service says they are gone
                                    try self.annotationStore.deleteLinkWithID(linkID)
                                }
                                // Add new links now
                                if let links = rawAnnotation["refs"] as? [String: [[String: AnyObject]]] {
                                    for link in links["ref"] ?? [] {
                                        guard let name = link["$"] as? String else {
                                            throw Error.errorWithCode(.InvalidLink, failureReason: "Failed to deserialize link: \(link)")
                                        }
                                        
                                        guard let paragraphAIDs = link["@pid"] as? String, docID = link["@docId"] as? String, docVersionString = link["@contentVersion"] as? String, docVersion = Int(docVersionString) else {
                                            throw Error.errorWithCode(.InvalidParagraphAID, failureReason: "Failed to deserialize link, missing PID: \(link)")
                                        }
                                        
                                        try self.annotationStore.addLink(name: name, docID: docID, docVersion: docVersion, paragraphAIDs: paragraphAIDs.componentsSeparatedByString(",").map { $0.trimmed() }, annotationID: annotationID)
                                        self.downloadLinkCount += 1
                                    }
                                }
                                
                                // MARK: Tags
                                
                                // Remove any existings tags from the annotation and then we'll re-added what the server sends us
                                for tagID in self.annotationStore.tagsWithAnnotationID(annotationID).flatMap({ $0.id }) {
                                    try self.annotationStore.deleteTag(tagID: tagID, fromAnnotation: annotationID)
                                }
                                if let tags = rawAnnotation["tags"] as? [String: [String]] {
                                    for tagName in tags["tag"] ?? [] {
                                        try self.annotationStore.addTag(name: tagName, annotationID: annotationID)
                                        self.downloadTagCount += 1
                                    }
                                }
                            }
                        }
                    } catch {
                        // Failed to deserialize this annotation, instead of failing the entire sync, just skip this annotation, and keep track of the error in case the client wants to do something with the errors
                        
                        let annotationData = try? NSJSONSerialization.dataWithJSONObject(rawAnnotation, options: .PrettyPrinted)
                        let annotationString = annotationData.flatMap { String(data: $0, encoding: NSUTF8StringEncoding) }
                        
                        let error = Error.errorWithCode(.SyncDeserializationFailed, failureReason: String(format: "Unable to deserialize annotation: %@", annotationString ?? rawAnnotation))
                        deserializationErrors.append(error)
                    }
                case .Trash, .Delete:
                    if let existingAnnotationID = annotationStore.annotationWithUniqueID(uniqueID)?.id {
                        // Don't store trashed or deleted annotations, just delete them from the db
                        try annotationStore.deleteAnnotationWithID(existingAnnotationID)
                    } else {
                        // If the annotation doesn't exist there's no need to delete it
                    }
                }
            }
        }
        
        // Cleanup any annotations with the 'trashed' or 'deleted' status after they've been sync'ed successfully, there's no benefit to storing them locally anymore
        let annotationsToDelete = annotationStore.allAnnotations(lastModifiedOnOrBefore: onOrBefore).filter { $0.status != .Active }
        for annotation in annotationsToDelete {
            try annotationStore.deleteAnnotationWithID(annotation.id)
        }
    }
    
}

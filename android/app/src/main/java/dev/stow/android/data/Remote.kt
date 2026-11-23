package dev.stow.android.data

import android.net.Uri
import android.util.Base64
import com.google.firebase.FirebaseApp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.FirebaseFirestoreException
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.firestore.Source
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.tasks.await

/**
 * The phone's side of the Firestore layout the Mac writes (see firebase/firestore.rules):
 * members/{uid}, pairing/{code}, channels/{id}, videos/{id}, secrets/cookies and secrets/feeds. The phone signs
 * in anonymously and can only read anything once the Mac has paired it.
 */
class Remote {
    private val auth = FirebaseAuth.getInstance()
    private val db = FirebaseFirestore.getInstance()

    val projectId: String get() = FirebaseApp.getInstance().options.projectId ?: ""
    val uid: String? get() = auth.currentUser?.uid

    /** Thrown when the Mac unpaired this phone (or never paired it). */
    class NotPaired : Exception("This phone isn't paired with the Mac.")

    // Pairing

    data class Invite(val projectId: String, val code: String, val key: String)

    /** stow://pair?p=<project>&c=<code>&k=<key>, from the Mac's QR code. */
    fun parseInvite(text: String): Invite? {
        val uri = runCatching { Uri.parse(text.trim()) }.getOrNull() ?: return null
        if (uri.scheme != "stow" || uri.host != "pair") return null
        val project = uri.getQueryParameter("p") ?: return null
        val code = uri.getQueryParameter("c") ?: return null
        val key = uri.getQueryParameter("k") ?: return null
        return Invite(project, code, key)
    }

    /**
     * Files a pairing request under the invite's code and waits until the Mac has added this
     * phone (members/{uid} becomes readable). Throws when it doesn't within `timeoutMs`.
     */
    suspend fun pair(invite: Invite, deviceName: String, timeoutMs: Long = 60_000) {
        require(invite.projectId == projectId) {
            "This QR code is for Firebase project ${invite.projectId}, but the app is built for $projectId."
        }
        val uid = signIn()
        val token = runCatching { FirebaseMessaging.getInstance().token.await() }.getOrNull()
        db.collection("pairing").document(invite.code)
            .set(mapOf("uid" to uid, "name" to deviceName, "fcmToken" to token)).await()
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            delay(1_500)
            try {
                if (db.collection("members").document(uid).get(Source.SERVER).await().exists()) return
            } catch (e: FirebaseFirestoreException) {
                if (e.code != FirebaseFirestoreException.Code.PERMISSION_DENIED) throw e
            }
        }
        throw IllegalStateException("The Mac didn't confirm the pairing. Is Stow running on it, with the QR code still open?")
    }

    /** Whether the Mac still has this phone as a member. */
    suspend fun isMember(): Boolean {
        val uid = uid ?: return false
        return try {
            db.collection("members").document(uid).get(Source.SERVER).await().exists()
        } catch (e: FirebaseFirestoreException) {
            if (e.code == FirebaseFirestoreException.Code.PERMISSION_DENIED) false else throw e
        }
    }

    fun signOut() = auth.signOut()

    private suspend fun signIn(): String {
        auth.currentUser?.let { return it.uid }
        return auth.signInAnonymously().await().user?.uid ?: error("Anonymous sign-in failed")
    }

    /** Sends this phone's current FCM token to the Mac (retrying while Play services warms up). */
    suspend fun refreshPushToken() {
        var attempt = 0
        while (true) {
            val token = runCatching { FirebaseMessaging.getInstance().token.await() }.getOrNull()
            if (token != null) return updatePushToken(token)
            if (++attempt >= 5) error("No FCM token")
            delay(5_000L * attempt)
        }
    }

    /** A new FCM token: keep the Mac's copy current so pushes reach this phone. */
    suspend fun updatePushToken(token: String) {
        val uid = uid ?: return
        db.collection("members").document(uid)
            .update(mapOf("fcmToken" to token, "lastSeenAt" to FieldValue.serverTimestamp())).await()
    }

    // Reading

    /** Every video sent to the phone, live. Fails with [NotPaired] once the Mac unpairs this phone. */
    fun videos(): Flow<List<SentVideo>> = callbackFlow {
        val registration: ListenerRegistration = db.collection("videos").addSnapshotListener { snapshot, error ->
            if (error != null) {
                close(if (error.code == FirebaseFirestoreException.Code.PERMISSION_DENIED) NotPaired() else error)
                return@addSnapshotListener
            }
            trySend(snapshot?.documents.orEmpty().mapNotNull { it.toSent() })
        }
        awaitClose { registration.remove() }
    }

    /** The Mac's channels with their newest videos, live. */
    fun channels(): Flow<List<Channel>> = callbackFlow {
        val registration = db.collection("channels").addSnapshotListener { snapshot, error ->
            if (error != null) {
                close(if (error.code == FirebaseFirestoreException.Code.PERMISSION_DENIED) NotPaired() else error)
                return@addSnapshotListener
            }
            trySend(snapshot?.documents.orEmpty().map { it.toChannel() }.sortedBy { it.order })
        }
        awaitClose { registration.remove() }
    }

    /** The videos as the server has them now (for background syncs). */
    suspend fun fetchVideos(): List<SentVideo> = try {
        db.collection("videos").get(Source.SERVER).await().documents.mapNotNull { it.toSent() }
    } catch (e: FirebaseFirestoreException) {
        if (e.code == FirebaseFirestoreException.Code.PERMISSION_DENIED) throw NotPaired() else throw e
    }

    /** The YouTube cookies (Netscape cookies.txt), decrypted; null when the Mac hasn't shared any. */
    suspend fun cookies(key: ByteArray): ByteArray? {
        val sealed = db.collection("secrets").document("cookies").get(Source.SERVER).await().getString("sealed") ?: return null
        return Crypto.open(Base64.decode(sealed, Base64.DEFAULT), key)
    }

    /** YouTube's Home and Subscriptions as the Mac last read them (sealed JSON), live; null until shared. */
    fun accountFeeds(): Flow<String?> = callbackFlow {
        val registration = db.collection("secrets").document("feeds").addSnapshotListener { snapshot, error ->
            if (error != null) {
                close(if (error.code == FirebaseFirestoreException.Code.PERMISSION_DENIED) NotPaired() else error)
                return@addSnapshotListener
            }
            trySend(snapshot?.getString("sealed"))
        }
        awaitClose { registration.remove() }
    }

    private fun com.google.firebase.firestore.DocumentSnapshot.toSent(): SentVideo? {
        val title = getString("title") ?: return null
        val video = Video(
            id = id,
            channelId = getString("channelId") ?: "",
            channelTitle = getString("channelTitle") ?: "",
            title = title,
            publishedAt = getTimestamp("publishedAt")?.toDate(),
            thumbnailUrl = getString("thumbnailURL"),
            isMembersOnly = getBoolean("isMembersOnly") ?: false,
            liveStatus = getString("liveStatus"),
        )
        return SentVideo(video, getTimestamp("sentAt")?.toDate(), getString("sentBy"), getBoolean("watched") ?: false)
    }

    private fun com.google.firebase.firestore.DocumentSnapshot.toChannel(): Channel {
        val title = getString("title") ?: id
        @Suppress("UNCHECKED_CAST")
        val recent = (get("recent") as? List<Map<String, Any?>>).orEmpty().mapNotNull { entry ->
            val videoId = entry["id"] as? String ?: return@mapNotNull null
            RecentVideo(
                Video(
                    id = videoId,
                    channelId = id,
                    channelTitle = title,
                    title = entry["title"] as? String ?: videoId,
                    publishedAt = (entry["publishedAt"] as? com.google.firebase.Timestamp)?.toDate(),
                    thumbnailUrl = entry["thumbnailURL"] as? String,
                    isMembersOnly = entry["isMembersOnly"] as? Boolean ?: false,
                    liveStatus = entry["liveStatus"] as? String,
                ),
                watched = entry["watched"] as? Boolean ?: false,
            )
        }
        return Channel(id, title, getString("handle"), getString("avatarURL"),
                       getLong("order")?.toInt() ?: 0, recent)
    }

    // Writing (only the fields the rules let a phone change)

    /** Asks for a video the Mac didn't send (picked from a channel page): files videos/{id}. */
    suspend fun requestDownload(video: Video) {
        db.collection("videos").document(video.id).set(mapOf(
            "channelId" to video.channelId,
            "channelTitle" to video.channelTitle,
            "title" to video.title,
            "publishedAt" to video.publishedAt?.let { com.google.firebase.Timestamp(it) },
            "thumbnailURL" to video.thumbnailUrl,
            "isMembersOnly" to video.isMembersOnly,
            "liveStatus" to video.liveStatus,
            "sentAt" to FieldValue.serverTimestamp(),
            "sentBy" to "phone",
            "watched" to false,
            "updatedAt" to FieldValue.serverTimestamp(),
            "updatedBy" to "phone",
        )).await()
    }

    suspend fun reportDownload(id: String, state: String, error: String? = null) {
        db.collection("videos").document(id).update(mapOf(
            "phone" to mapOf("state" to state, "error" to error),
            "updatedAt" to FieldValue.serverTimestamp(),
            "updatedBy" to "phone",
        )).await()
    }

    suspend fun setWatched(id: String, watched: Boolean) {
        db.collection("videos").document(id).update(mapOf(
            "watched" to watched,
            "watchedAt" to if (watched) FieldValue.serverTimestamp() else null,
            "watchedBy" to if (watched) "phone" else null,
            "updatedAt" to FieldValue.serverTimestamp(),
            "updatedBy" to "phone",
        )).await()
    }
}

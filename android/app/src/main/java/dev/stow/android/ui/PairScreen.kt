package dev.stow.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import dev.stow.android.data.PairState

/** Scan the QR code from Stow › Phone › Pair a Phone on the Mac. */
@Composable
fun PairScreen(state: PairState, onScanned: (String) -> Unit) {
    val context = LocalContext.current
    Column(
        modifier = Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Box(
            modifier = Modifier.size(88.dp).clip(RoundedCornerShape(24.dp)).background(StowGradient),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.PlayArrow, contentDescription = null, tint = Color.White, modifier = Modifier.size(52.dp))
        }
        Spacer(Modifier.height(24.dp))
        Text("Pair with your Mac", style = MaterialTheme.typography.headlineSmall)
        Spacer(Modifier.height(8.dp))
        Text(
            "On the Mac, open Stow › Phone › Pair a Phone, then scan the code it shows.",
            style = MaterialTheme.typography.bodyLarge,
            textAlign = TextAlign.Center,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(32.dp))
        when (state) {
            PairState.Pairing -> {
                CircularProgressIndicator()
                Spacer(Modifier.height(12.dp))
                Text("Waiting for the Mac…", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            else -> {
                Button(onClick = {
                    val options = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
                    GmsBarcodeScanning.getClient(context, options).startScan()
                        .addOnSuccessListener { barcode -> barcode.rawValue?.let(onScanned) }
                }) {
                    Icon(Icons.Filled.QrCodeScanner, contentDescription = null)
                    Spacer(Modifier.size(8.dp))
                    Text("Scan QR Code")
                }
                (state as? PairState.Unpaired)?.message?.let {
                    Spacer(Modifier.height(16.dp))
                    Text(it, color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center)
                }
            }
        }
    }
}

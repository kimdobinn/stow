package dev.stow.android.ui

import androidx.compose.runtime.remember
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.rounded.Laptop
import androidx.compose.material.icons.rounded.PhoneAndroid
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

/** The first screen: with the Mac (pair with a QR code) or on its own. */
@Composable
fun ModeScreen(onMac: () -> Unit, onStandalone: () -> Unit) {
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 48.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Box(Modifier.size(88.dp).clip(RoundedCornerShape(24.dp)).background(StowGradient), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.PlayArrow, contentDescription = null, tint = Color.White, modifier = Modifier.size(52.dp))
        }
        Spacer(Modifier.height(24.dp))
        Text("How do you want to use Stow?", style = StowType.title2, color = Stow.colors.text, textAlign = TextAlign.Center)
        Spacer(Modifier.height(28.dp))
        ModeChoice(Icons.Rounded.Laptop, "Use with my Mac",
                   "Your Mac follows your channels and sends videos here. You pair with a QR code.", primary = true, onClick = onMac)
        Spacer(Modifier.height(12.dp))
        ModeChoice(Icons.Rounded.PhoneAndroid, "Use on its own",
                   "This phone follows channels and checks for new videos itself. Signing in to YouTube is optional.", primary = false,
                   onClick = onStandalone)
        Spacer(Modifier.height(16.dp))
        Text("You can switch later in Settings.", style = StowType.footnote, color = Stow.colors.secondaryText)
    }
}

@Composable
private fun ModeChoice(icon: ImageVector, title: String, subtitle: String, primary: Boolean, onClick: () -> Unit) {
    val colors = Stow.colors
    val content = if (primary) Color.White else colors.text
    val interaction = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }
    Row(
        Modifier.fillMaxWidth().pressScale(interaction).clip(RoundedCornerShape(18.dp)).background(if (primary) colors.accent else colors.chip)
            .clickable(interactionSource = interaction, indication = androidx.compose.foundation.LocalIndication.current,
                       role = androidx.compose.ui.semantics.Role.Button, onClick = onClick).padding(18.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = content, modifier = Modifier.size(28.dp))
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = StowType.headline, color = content)
            Spacer(Modifier.height(2.dp))
            Text(subtitle, style = StowType.footnote, color = if (primary) Color.White.copy(alpha = 0.88f) else colors.secondaryText)
        }
    }
}

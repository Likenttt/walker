using Toybox.WatchUi as Ui;
using Toybox.Application as App;
using Toybox.Math as Math;
using Toybox.UserProfile as User;

class WalkerView extends Ui.DataField {
	
	/* NOTE: Violation of SOLID principles (and general good maintainable code hygene) here is intentional. Some Garmin watches only
	 * give you 16KB (!) of memory to work with for a DataField, and about 9KB of that allowance gets used up on the DataField itself
	 * before you've written a line of code. Keeping memory usage that low is a challenge, and requires a Scrooge-like accounting of
	 * memory allocations. No unnecessary intermediate variables, no single instance classes, no single call functions etc. It makes
	 * the code hard to read, but the codebase is sufficiently small that it shouldn't be a problem
	 */
	
	var is24Hour = false;
	
	var previousDarkMode;
	
	var stepsIcon;
	var caloriesIcon;
	
	var batteryIconColour;
	var batteryTextColour;
	var heartRateIconColour;
	var heartRateZoneTextColour;
	
	var paceOrSpeedData;
	var heartRateData;
	
	var previousDaySteps = 0;
	var stepsWhenTimerBecameActive = 0;
	var activityStepsAtPreviousLap = 0;
	var consolidatedSteps = 0;
	
	// User definable settings. Stored as numbers rather than enums because enums waste valuable memory.
	var paceOrSpeedMode = 0;
	var heartRateMode = 0;
	var showHeartRateZone = false;
	var showSpeedInsteadOfPace = false;
	
	var timerActive = false;
	
	var kmOrMileInMetersDistance;
	var kmOrMileInMetersPace;
	var averagePaceOrSpeedUnitsLabel;
	var distanceUnitsLabel;
	
	// Calculated values that change on every call to compute()
	var steps;
	var lapSteps;
	var averagePaceOrSpeed;
	var distance;
	var heartRate;
	var heartRateZone;
	var paceOrSpeed;
	var time;
	var daySteps;
	var calories;
	var dayCalories;
	var stepGoalProgress;
	
	// FIT contributor fields
	var stepsActivityField;
	var stepsLapField;
	
	(:memory16k) var view32;
	
	function initialize() {
	
		DataField.initialize();
		
		if (WalkerView has :view32) {
			view32 = new WalkerViewGTE32K();
		}
		
		readSettings();
		
		var app = Application.getApp();
		var info = Activity.getActivityInfo();
		
		// If the activity has restarted after "resume later", load previously stored steps values
		if (info != null && info.elapsedTime > 0) {
	        steps = app.getProperty("as");
	        lapSteps = app.getProperty("ls");
	        if (steps == null) { steps = 0; }
	        if (lapSteps == null) { lapSteps = 0; }
	    }
		
		var stepsUnits = Ui.loadResource(Rez.Strings.stepsUnits);
		
		// Create FIT contributor fields
		stepsActivityField = createField(Ui.loadResource(Rez.Strings.steps), 0, 2 /* Fit.DATA_TYPE_UINT8 */,
            { :mesgType => 18 /* Fit.MESG_TYPE_SESSION */, :units => stepsUnits });
        stepsLapField = createField(Ui.loadResource(Rez.Strings.steps), 1, 2 /* Fit.DATA_TYPE_UINT8 */,
            { :mesgType => 19 /* Fit.MESG_TYPE_LAP */, :units => stepsUnits });
        
        // Set initial steps FIT contributions to zero
        stepsActivityField.setData(0);
        stepsLapField.setData(0);
        
        // Clean up memory
        app = null;
        info = null;
	}
	
	// Called on initialization and when settings change (from a hook in WalkerApp.mc)
	function readSettings() {
		
		var deviceSettings = System.getDeviceSettings();
		var app = Application.getApp();
		
		is24Hour = deviceSettings.is24Hour;
		
		paceOrSpeedMode = app.getProperty("pm");
		if (paceOrSpeedMode > 0) {
			paceOrSpeedData = new DataQueue(paceOrSpeedMode);
		} else {
			paceOrSpeedData = null;
		}
		
		heartRateMode = app.getProperty("hm");
		if (heartRateMode > 0) {
			heartRateData = new DataQueue(heartRateMode);
		} else {
			heartRateData = null;
		}
		
		showHeartRateZone = app.getProperty("z");
		showSpeedInsteadOfPace = app.getProperty("s");
		
		kmOrMileInMetersDistance = deviceSettings.distanceUnits == 0 /* System.UNIT_METRIC */ ? 1000.0f : 1609.34f;
		kmOrMileInMetersPace = deviceSettings.paceUnits == 0 /* System.UNIT_METRIC */ ? 1000.0f : 1609.34f;
		distanceUnitsLabel = deviceSettings.distanceUnits == 0 /* System.UNIT_METRIC */ ? "km" : "mi";
		averagePaceOrSpeedUnitsLabel = showSpeedInsteadOfPace ? "/hr" : "/" + (deviceSettings.paceUnits == 0 /* System.UNIT_METRIC */ ? "km" : "mi");
		
		if (WalkerView has :view32) {
			view32.readSettings(self, deviceSettings, app);
		}
		
		// Clean up memory
		deviceSettings = null;
		app = null;
	}
	
	// Handle activity timer events
	function onTimerStart() { timerStart(); }
	function onTimerResume() { timerStart(); }
	function onTimerStop() { timerStop(); }
	function onTimerPause() { timerStop(); }
	function onTimerLap() { activityStepsAtPreviousLap = steps; }
	
	function onTimerReset() {
		consolidatedSteps = 0;
		stepsWhenTimerBecameActive = 0;
		activityStepsAtPreviousLap = 0;
		previousDaySteps = 0;
		steps = 0;
		lapSteps = 0;
		timerActive = false;
	}
	
	function timerStart() {
		stepsWhenTimerBecameActive = ActivityMonitor.getInfo().steps;
		timerActive = true;
	}
	
	function timerStop() {
		consolidatedSteps = steps;
		timerActive = false;
	}
	
	function compute(info) {
		
		var activityMonitorInfo = ActivityMonitor.getInfo();
		
		// Distance
		distance = info.elapsedDistance;
		
		// Heart rate
		if (heartRateData != null) {
			if (info.currentHeartRate != null) {
				heartRateData.add(info.currentHeartRate);
			} else {
				heartRateData.reset();
			}
		}
		heartRate = heartRateMode <= 0
			? info.currentHeartRate
			: heartRateData != null
				? heartRateData.average()
				: null;
		
		// Heart rate zone
		if (showHeartRateZone) {
			var heartRateZones = User.getHeartRateZones(User.getCurrentSport());
			heartRateZone = '-';
			if (heartRate != null && heartRate > heartRateZones[0]) {
				for (var x = 1; x < heartRateZones.size(); x++) {
					if (heartRate <= heartRateZones[x]) {
						heartRateZone = x;
						break;
					}
					// We're apparently over the maximum for the highest heart rate zone, so just max out.
					heartRateZone = '+';
				}
			}
		}
		
		// Pace or speed
		if (paceOrSpeedData != null) {
			if (info.currentSpeed != null) {
				paceOrSpeedData.add(info.currentSpeed);
			} else {
				paceOrSpeedData.reset();
			}
		}
		var speed = paceOrSpeedMode == 0
			? info.currentSpeed
			: paceOrSpeedData != null
				? paceOrSpeedData.average()
				: null;
		paceOrSpeed = speed != null && speed > 0.2 // Walking at a speed of less than 1km per hour probably isn't walking
			? (showSpeedInsteadOfPace
				? speed
				: kmOrMileInMetersPace / speed) * 1000.0
			: null;
		averagePaceOrSpeed = info.averageSpeed != null && info.averageSpeed > 0.2 // Walking at a speed of less than 1km per hour probably isn't walking
			? (showSpeedInsteadOfPace
				? info.averageSpeed
				: (kmOrMileInMetersPace / info.averageSpeed)) * 1000.0
			: null;
		
		// Time
		time = info.timerTime;
		
		// Day steps
		daySteps = activityMonitorInfo.steps;
		if (previousDaySteps > 0 && daySteps < previousDaySteps) {
			// Uh-oh, the daily step count has reduced - out for a midnight stroll are we?
			stepsWhenTimerBecameActive -= previousDaySteps;
		}
		previousDaySteps = daySteps;
		
		// Steps
		if (timerActive) {
			steps = consolidatedSteps + daySteps - stepsWhenTimerBecameActive;
			lapSteps = steps - activityStepsAtPreviousLap;
			
			// Update step FIT contributions
			stepsActivityField.setData(steps);
			stepsLapField.setData(lapSteps);
		}
		stepGoalProgress = activityMonitorInfo.stepGoal != null && activityMonitorInfo.stepGoal > 0
			? daySteps > activityMonitorInfo.stepGoal
				? 1
				: daySteps / activityMonitorInfo.stepGoal.toFloat()
			: 0;
		
		// Calories
		calories = info.calories;
		dayCalories = activityMonitorInfo.calories;
		
		if (WalkerView has :view32) {
			view32.compute(self, info, activityMonitorInfo);
		}
		
		// Clean up memory
		activityMonitorInfo = null;
	}
	
	function onUpdate(dc) {
	
		var halfWidth = dc.getWidth() / 2;
		var paceOrSpeedText = showSpeedInsteadOfPace
			? formatDistance(paceOrSpeed == null ? null : paceOrSpeed, kmOrMileInMetersPace)
			: formatTime(paceOrSpeed == null ? null : paceOrSpeed, false);
		var timeText = formatTime(time == null ? null : time, false);
		var shrinkMiddleText = paceOrSpeedText.length() > 5 || timeText.length() > 5;
		
		// Set colours
		var backgroundColour = WalkerView has :getBackgroundColor ? getBackgroundColor() : 0xFFFFFF /* Gfx.COLOR_WHITE */;
		var darkMode = backgroundColour == 0x000000 /* Gfx.COLOR_BLACK */;
		
		// Choose the colour of the battery based on it's state
		var battery = System.getSystemStats().battery;
		var batteryState = battery >= 50
			? 0
			: battery <= 10
				? 1
				: battery <= 20
					? 2
					: 3;
		batteryTextColour = 0xFFFFFF /* Gfx.COLOR_WHITE */;
		if (batteryState == 0) {
			batteryIconColour = 0x00AA00 /* Gfx.COLOR_DK_GREEN */;
		} else if (batteryState == 1) {
			batteryIconColour = 0xFF0000 /* Gfx.COLOR_RED */;
			batteryTextColour = 0xFFFFFF /* Gfx.COLOR_WHITE */;
		} else if (batteryState == 2) {
			batteryIconColour = 0xFFAA00 /* Gfx.COLOR_YELLOW */;
		} else {
			batteryIconColour = darkMode ?  0xAAAAAA /* Gfx.COLOR_LT_GRAY */ :  0x555555 /* Gfx.COLOR_DK_GRAY */;
			if (darkMode) { batteryTextColour = 0x000000; }
		}
		
		// Choose the colour of the heart rate icon based on heart rate zone
		heartRateZoneTextColour = 0xFFFFFF /* Gfx.COLOR_WHITE */;
		if (heartRateZone == '-') {
			if (darkMode) {
				heartRateIconColour = 0x555555 /* Gfx.COLOR_DK_GRAY */;
			} else {
				heartRateIconColour = 0xAAAAAA /* Gfx.COLOR_LT_GRAY */;
				heartRateZoneTextColour = 0x000000 /* Gfx.COLOR_BLACK */;
			}
		} else if (heartRateZone == 1) {
			if (darkMode) {
				heartRateIconColour = 0xAAAAAA /* Gfx.COLOR_LT_GRAY */;
				heartRateZoneTextColour = 0x000000 /* Gfx.COLOR_BLACK */;
			} else {
				heartRateIconColour = 0x555555 /* Gfx.COLOR_DK_GRAY */;
			}
		} else if (heartRateZone == 2) {
			heartRateIconColour = 0x00AAFF /* Gfx.COLOR_BLUE */;
		} else if (heartRateZone == 3) {
			heartRateIconColour = 0x00AA00 /* Gfx.COLOR_DK_GREEN */;
		} else if (heartRateZone == 4) {
			heartRateIconColour = 0xFFAA00 /* Gfx.COLOR_YELLOW */;
			heartRateZoneTextColour = 0x000000 /* Gfx.COLOR_BLACK */;
		} else {
			heartRateIconColour = 0xFF0000 /* Gfx.COLOR_RED */;
		}
		
		// Max width values for layout debugging
		/*
		averagePaceOrSpeed = 100000;
		distance = 888888.888;
		heartRate = 888;
		paceOrSpeedText = "8:88:88";
		timeText = "8:88:88";
		steps = 88888;
		daySteps = 88888;
		calories = 88888;
		dayCalories = 88888;
		stepGoalProgress = 0.75;
		shrinkMiddleText = true;
		*/
		
		// Realistic static values for screenshots
		/*
		averagePaceOrSpeed = 44520;
		distance = 1921;
		heartRate = 106;
		paceOrSpeedText = "12:15";
		timeText = "23:31";
		steps = 2331;
		daySteps = 7490;
		calories = 135;
		dayCalories = 1742;
		stepGoalProgress = 0.75;
		*/
		
		// If we've never loaded the icons before or dark mode has been toggled, load the icons
		if (previousDarkMode != darkMode) {
			previousDarkMode = darkMode;
			stepsIcon = Ui.loadResource(darkMode ? Rez.Drawables.isd : Rez.Drawables.is);
			caloriesIcon = Ui.loadResource(darkMode ? Rez.Drawables.icd : Rez.Drawables.ic);
		}
		
		// Render background
		dc.setColor(backgroundColour, backgroundColour);
		dc.fillRectangle(0, 0, dc.getWidth(), dc.getHeight());
		
		// Render horizontal lines
		dc.setColor(0xAAAAAA /* Gfx.COLOR_LT_GRAY */, -1 /* Gfx.COLOR_TRANSPARENT */);
		for (var x = 0; x < lines.size(); x++) {
        	dc.drawLine(0, lines[x], dc.getWidth(), lines[x]);
		}
		
		// Render vertical lines
		dc.drawLine(halfWidth, lines[0], halfWidth, lines[1]);
		dc.drawLine(halfWidth, lines[2], halfWidth, lines[3]);
		
		// Render step goal progress bar
		if (stepGoalProgress != null && stepGoalProgress > 0) {
			dc.setColor(darkMode ? 0x00FF00 /* Gfx.COLOR_GREEN */ : 0x00AA00 /* Gfx.COLOR_DK_GREEN */, -1 /* Gfx.COLOR_TRANSPARENT */);
			dc.drawRectangle(stepGoalProgressOffsetX, lines[2] - 1, (dc.getWidth() - (stepGoalProgressOffsetX * 2)) * stepGoalProgress, 3);
		}
		
		// Set text rendering colour
		dc.setColor(darkMode ? 0xFFFFFF /* Gfx.COLOR_WHITE */ : 0x000000 /* Gfx.COLOR_BLACK */, -1 /* Gfx.COLOR_TRANSPARENT */);
		
		// Render clock
		var currentTime = System.getClockTime();
		var hour = is24Hour ? currentTime.hour : currentTime.hour % 12;
		if (!is24Hour && hour == 0) { hour = 12; }
		dc.drawText(halfWidth + clockOffsetX, clockY, timeFont,
			hour.format(is24Hour ? "%02d" : "%d")
			  + ":"
			  + currentTime.min.format("%02d")
			  + (is24Hour ? "" : currentTime.hour >= 12 ? "pm" : "am"),
			  1 /* Gfx.TEXT_JUSTIFY_CENTER */ | 4 /* Gfx.TEXT_JUSTIFY_VCENTER */);
		
		// Render average pace or speed
		dc.drawText(halfWidth - centerOffsetX, topRowY, topRowFont,
			showSpeedInsteadOfPace
				? formatDistance(averagePaceOrSpeed == null ? null : averagePaceOrSpeed, kmOrMileInMetersPace) + averagePaceOrSpeedUnitsLabel
				: formatTime(averagePaceOrSpeed == null ? null : averagePaceOrSpeed, true) + averagePaceOrSpeedUnitsLabel,
			0 /* Gfx.TEXT_JUSTIFY_RIGHT */ | 4 /* Gfx.TEXT_JUSTIFY_VCENTER */);
		
		// Render distance
		dc.drawText(halfWidth + centerOffsetX, topRowY, topRowFont,
			formatDistance(distance, kmOrMileInMetersDistance) + distanceUnitsLabel, 2 /* Gfx.TEXT_JUSTIFY_LEFT */ | 4 /* Gfx.TEXT_JUSTIFY_VCENTER */);
		
		// Render heart rate text
		var heartRateText = (heartRate == null ? 0 : heartRate).format("%d");
		var heartRateWidth = dc.getTextDimensions(heartRateText, heartRateFont)[0];
		dc.drawText(halfWidth, heartRateTextY, heartRateFont,
			heartRateText, 1 /* Gfx.TEXT_JUSTIFY_CENTER */ | 4 /* Gfx.TEXT_JUSTIFY_VCENTER */);
		
		// Render heart rate icon
		dc.setColor(heartRateIconColour, -1 /* Gfx.COLOR_TRANSPARENT */);
		dc.fillCircle(halfWidth - (heartRateIconWidth / 4.7), heartRateIconY + (heartRateIconWidth / 3.2), heartRateIconWidth / 3.2);
		dc.fillCircle(halfWidth + (heartRateIconWidth / 4.7), heartRateIconY + (heartRateIconWidth / 3.2), heartRateIconWidth / 3.2);
		dc.fillPolygon([
			[halfWidth - (heartRateIconWidth / 2.2), heartRateIconY + (heartRateIconWidth / 1.8) - heartRateIconXOffset],
			[halfWidth, heartRateIconY + (heartRateIconWidth * 0.95)],
			[halfWidth + (heartRateIconWidth / 2.2), heartRateIconY + (heartRateIconWidth / 1.8) - heartRateIconXOffset]
		]);
		
		if (showHeartRateZone && heartRateZone != null) {
			dc.setColor(heartRateZoneTextColour, -1 /* Gfx.COLOR_TRANSPARENT */);
			dc.drawText(halfWidth, heartRateIconY + (heartRateIconWidth / 2) - 3, 0 /* Gfx.FONT_XTINY */,
				heartRateZone.toString(), 1 /* Gfx.TEXT_JUSTIFY_CENTER */ | 4 /* Gfx.TEXT_JUSTIFY_VCENTER */);
		}
		
		// Reset text rendering colour
		dc.setColor(darkMode ? 0xFFFFFF /* Gfx.COLOR_WHITE */ : 0x000000 /* Gfx.COLOR_BLACK */, -1 /* Gfx.COLOR_TRANSPARENT */);
		
		// Render current pace or speed
		dc.drawText((halfWidth / 2) - (heartRateWidth / 2) + 5, middleRowLabelY, middleRowLabelFont,
			Ui.loadResource(showSpeedInsteadOfPace ? Rez.Strings.speed : Rez.Strings.pace),
			1 /* Gfx.TEXT_JUSTIFY_CENTER */ | 4 /* Gfx.TEXT_JUSTIFY_VCENTER */);
		dc.drawText(
		(halfWidth / 2) - (heartRateWidth / 2) + 5,
			middleRowValueY,
			shrinkMiddleText ? middleRowValueFontShrunk : middleRowValueFont,
			paceOrSpeedText,
			1 /* Gfx.TEXT_JUSTIFY_CENTER */ | 4 /* Gfx.TEXT_JUSTIFY_VCENTER */);
		
		// Render timer
		dc.drawText((halfWidth * 1.5) + (heartRateWidth / 2) - 5, middleRowLabelY, middleRowLabelFont,
			Ui.loadResource(Rez.Strings.timer), 1 /* Gfx.TEXT_JUSTIFY_CENTER */ | 4 /* Gfx.TEXT_JUSTIFY_VCENTER */);
		dc.drawText(
			(halfWidth * 1.5) + (heartRateWidth / 2) - 5,
			middleRowValueY,
			shrinkMiddleText ? middleRowValueFontShrunk : middleRowValueFont,
			timeText,
			1 /* Gfx.TEXT_JUSTIFY_CENTER */ | 4 /* Gfx.TEXT_JUSTIFY_VCENTER */);
		
		// Render steps
		dc.drawBitmap(bottomRowIconX, bottomRowIconY, stepsIcon);
		dc.drawText(halfWidth - centerOffsetX, bottomRowUpperTextY, bottomRowFont,
			(steps == null ? 0 : steps).format("%d"), 0 /* Gfx.TEXT_JUSTIFY_RIGHT */ | 4 /* Gfx.TEXT_JUSTIFY_VCENTER */);
		
		// Render calories
		dc.drawBitmap(dc.getWidth() - bottomRowIconX - caloriesIcon.getWidth(), bottomRowIconY, caloriesIcon);
		dc.drawText(halfWidth + centerOffsetX, bottomRowUpperTextY, bottomRowFont,
			(calories == null ? 0 : calories).format("%d"), 2 /* Gfx.TEXT_JUSTIFY_LEFT */ | 4 /* Gfx.TEXT_JUSTIFY_VCENTER */);
		
		// Set grey colour for day counts
		dc.setColor(0x555555 /* Gfx.COLOR_DK_GRAY */, -1 /* Gfx.COLOR_TRANSPARENT */);
		
		// Render day steps
		dc.drawText(halfWidth - centerOffsetX, bottomRowLowerTextY, bottomRowFont,
			(daySteps == null ? 0 : daySteps).format("%d"), 0 /* Gfx.TEXT_JUSTIFY_RIGHT */ | 4 /* Gfx.TEXT_JUSTIFY_VCENTER */);
		
		// Render day calories
		dc.drawText(halfWidth + centerOffsetX, bottomRowLowerTextY, bottomRowFont,
			(dayCalories == null ? 0 : dayCalories).format("%d"), 2 /* Gfx.TEXT_JUSTIFY_LEFT */ | 4 /* Gfx.TEXT_JUSTIFY_VCENTER */);
		
		// Render battery
		dc.setColor(batteryIconColour, -1 /* Gfx.COLOR_TRANSPARENT */);
		dc.fillRoundedRectangle(halfWidth - (batteryWidth / 2) + 2 + batteryX, batteryY - (batteryHeight / 2), batteryWidth - 4, batteryHeight, 2);
		dc.fillRoundedRectangle(halfWidth - (batteryWidth / 2) + 2 + batteryX + batteryWidth - 7, batteryY - (batteryHeight / 2) + 4, 7, batteryHeight - 8, 2);
		dc.setColor(batteryTextColour, -1 /* Gfx.COLOR_TRANSPARENT */);
		dc.drawText(halfWidth + batteryX, batteryY - 1, batteryFont,
			battery.format("%d") + "%", 1 /* Gfx.TEXT_JUSTIFY_CENTER */ | 4 /* Gfx.TEXT_JUSTIFY_VCENTER */);
		
		if (WalkerView has :view32) {
			view32.onUpdate(self, dc);
		}
	}
	
	function formatTime(milliseconds, short) {
		if (milliseconds != null && milliseconds > 0) {
			var hours = null;
			var minutes = Math.floor(milliseconds / 1000 / 60).toNumber();
			var seconds = Math.floor(milliseconds / 1000).toNumber() % 60;
			if (minutes >= 60) {
				hours = minutes / 60;
				minutes = minutes % 60;
			}
			if (hours == null) {
				return minutes.format("%d") + ":" + seconds.format("%02d");
			} else if (short) {
				return hours.format("%d") + ":" + minutes.format("%02d");
			} else {
				return hours.format("%d") + ":" + minutes.format("%02d") + ":" + seconds.format("%02d");
			}
		} else {
			return "0:00";
		}
	}
	
	function formatDistance(meters, kmOrMileInMeters) {
		if (meters != null && meters > 0) {
			var distanceKmOrMiles = meters / kmOrMileInMeters;
			if (distanceKmOrMiles >= 1000) {
				return distanceKmOrMiles.format("%d");
			} else if (distanceKmOrMiles >= 100) {
				return distanceKmOrMiles.format("%.1f");
			} else {
				return distanceKmOrMiles.format("%.2f");
			}
		} else {
			return "0.00";
		}
	}

}

import QtQuick 2.0;
import calamares.slideshow 1.0;

Presentation
{
    id: presentation

    Slide {
        Rectangle {
            anchors.fill: parent
            color: "#111111"
            Image {
                id: logo
                source: "logo.png"
                anchors.centerIn: parent
                width: Math.min(parent.width * 0.45, 280)
                fillMode: Image.PreserveAspectFit
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: logo.bottom
                anchors.topMargin: 16
                text: "AnanasOS"
                color: "#F5C542"
                font.pixelSize: 28
            }
        }
    }

    function onActivate() {
        presentation.currentSlide = 0;
    }

    function onLeave() {
    }
}

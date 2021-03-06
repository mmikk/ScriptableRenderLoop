using System;
using UnityEditor;

namespace UnityEngine.Experimental.Rendering.HDPipeline
{
    [Serializable]
    public class SubsurfaceScatteringProfile
    {
        public const int numSamples = 7; // Must be an odd number
        
        [SerializeField, ColorUsage(false, true, 0.05f, 2.0f, 1.0f, 1.0f)]
        Color       m_StdDev1;
        [SerializeField, ColorUsage(false, true, 0.05f, 2.0f, 1.0f, 1.0f)]
        Color       m_StdDev2;
        [SerializeField]
        float       m_LerpWeight;
        [SerializeField]
        Vector4[]   m_FilterKernel;
        [SerializeField]
        public bool m_KernelNeedsUpdate;

        // --- Public Methods ---

        public SubsurfaceScatteringProfile()
        {
            m_StdDev1    = new Color(0.3f, 0.3f, 0.3f, 0.0f);
            m_StdDev2    = new Color(1.0f, 1.0f, 1.0f, 0.0f);
            m_LerpWeight = 0.5f;
            ComputeKernel();
        }

        public Color stdDev1
        {
            get { return m_StdDev1; }
            set { if (m_StdDev1 != value) { m_StdDev1 = value; m_KernelNeedsUpdate = true; } }
        }

        public Color stdDev2
        {
            get { return m_StdDev2; }
            set { if (m_StdDev2 != value) { m_StdDev2 = value; m_KernelNeedsUpdate = true; } }
        }

        public float lerpWeight
        {
            get { return m_LerpWeight; }
            set { if (m_LerpWeight != value) { m_LerpWeight = value; m_KernelNeedsUpdate = true; } }
        }

        public Vector4[] filterKernel
        {
            get { if (m_KernelNeedsUpdate) ComputeKernel(); return m_FilterKernel; }
        }

        public void SetDirtyFlag()
        {
            m_KernelNeedsUpdate = true;
        }

        // --- Private Methods ---

        static float Gaussian(float x, float stdDev)
        {
            float variance = stdDev * stdDev;
            return Mathf.Exp(-x * x / (2 * variance)) / Mathf.Sqrt(2 * Mathf.PI * variance);
        }

        static float GaussianCombination(float x, float stdDev1, float stdDev2, float lerpWeight)
        {
            return Mathf.Lerp(Gaussian(x, stdDev1), Gaussian(x, stdDev2), lerpWeight);
        }

        static float RationalApproximation(float t)
        {
            // Abramowitz and Stegun formula 26.2.23.
            // The absolute value of the error should be less than 4.5 e-4.
            float[] c = {2.515517f, 0.802853f, 0.010328f};
            float[] d = {1.432788f, 0.189269f, 0.001308f};
            return t - ((c[2] * t + c[1]) * t + c[0]) / (((d[2] * t + d[1]) * t + d[0]) * t + 1.0f);
        }
 
        // Ref: https://www.johndcook.com/blog/csharp_phi_inverse/
        static float NormalCdfInverse(float p, float stdDev)
        {
            float x;

            if (p < 0.5)
            {
                // F^-1(p) = - G^-1(p)
                x = -RationalApproximation(Mathf.Sqrt(-2.0f * Mathf.Log(p)));
            }
            else
            {
                // F^-1(p) = G^-1(1-p)
                x = RationalApproximation(Mathf.Sqrt(-2.0f * Mathf.Log(1.0f - p)));
            }

            return x * stdDev;
        }

        static float GaussianCombinationCdfInverse(float p, float stdDev1, float stdDev2, float lerpWeight)
        {
            return Mathf.Lerp(NormalCdfInverse(p, stdDev1), NormalCdfInverse(p, stdDev2), lerpWeight);
        }

        void ComputeKernel()
        {
            if (m_FilterKernel == null || m_FilterKernel.Length != numSamples)
            {
                m_FilterKernel = new Vector4[numSamples];
            }

            // Our goal is to blur the image using a filter which is represented
            // as a product of a linear combination of two normalized 1D Gaussians
            // as suggested by Jimenez et al. in "Separable Subsurface Scattering".
            // A normalized (i.e. energy-preserving) 1D Gaussian with the mean of 0
            // is defined as follows: G1(x, v) = exp(-x� / (2 * v)) / sqrt(2 * Pi * v),
            // where 'v' is variance and 'x' is the radial distance from the origin.
            // Using the weight 'w', our 1D and the resulting 2D filters are given as:
            // A1(v1, v2, w, x)    = G1(x, v1) * (1 - w) + G1(r, v2) * w,
            // A2(v1, v2, w, x, y) = A1(v1, v2, w, x) * A1(v1, v2, w, y).
            // The resulting filter function is a non-Gaussian PDF.
            // It is separable by design, but generally not radially symmetric.

            // Find the widest Gaussian across 3 color channels.
            float maxStdDev1 = Mathf.Max(m_StdDev1.r, m_StdDev1.g, m_StdDev1.b);
            float maxStdDev2 = Mathf.Max(m_StdDev2.r, m_StdDev2.g, m_StdDev2.b);

            Vector3 weightSum = new Vector3(0, 0, 0); 

            // Importance sample the linear combination of two Gaussians.
            for (uint i = 0; i < numSamples; i++)
            {
                float u   = (i + 0.5f) / numSamples;
                float pos = GaussianCombinationCdfInverse(u, maxStdDev1, maxStdDev2, m_LerpWeight);
                float pdf = GaussianCombination(pos, maxStdDev1, maxStdDev2, m_LerpWeight);

                Vector3 val;
                val.x = GaussianCombination(pos, m_StdDev1.r, m_StdDev2.r, m_LerpWeight);
                val.y = GaussianCombination(pos, m_StdDev1.g, m_StdDev2.g, m_LerpWeight);
                val.z = GaussianCombination(pos, m_StdDev1.b, m_StdDev2.b, m_LerpWeight);

                m_FilterKernel[i].x = val.x / (pdf * numSamples);
                m_FilterKernel[i].y = val.y / (pdf * numSamples);
                m_FilterKernel[i].z = val.z / (pdf * numSamples);
                m_FilterKernel[i].w = pos;

                weightSum.x += m_FilterKernel[i].x;
                weightSum.y += m_FilterKernel[i].y;
                weightSum.z += m_FilterKernel[i].z;
            }

            // Renormalize the weights to conserve energy.
            for (uint i = 0; i < numSamples; i++)
            {
                m_FilterKernel[i].x *= 1.0f / weightSum.x;
                m_FilterKernel[i].y *= 1.0f / weightSum.y;
                m_FilterKernel[i].z *= 1.0f / weightSum.z;
            }

            m_KernelNeedsUpdate = false;
        }
    }

    public class SubsurfaceScatteringParameters : ScriptableObject
    {
        const int m_maxNumProfiles = 8;
        [SerializeField]
        int m_NumProfiles;
        [SerializeField]
        SubsurfaceScatteringProfile[] m_Profiles;
        [SerializeField]
        float m_BilateralScale;

        // --- Public Methods ---

        public SubsurfaceScatteringParameters()
        {
            m_NumProfiles    = 1;
            m_Profiles       = new SubsurfaceScatteringProfile[m_NumProfiles];
            m_BilateralScale = 0.1f;

            for (int i = 0; i < m_NumProfiles; i++)
            {
                m_Profiles[i] = new SubsurfaceScatteringProfile();
            }
        }

        public SubsurfaceScatteringProfile[] profiles       { set { m_Profiles       = value; OnValidate(); } get { return m_Profiles; } }
        public float                         bilateralScale { set { m_BilateralScale = value; OnValidate(); } get { return m_BilateralScale; } }

        public void SetDirtyFlag()
        {
            for (int i = 0; i < m_Profiles.Length; i++)
            {
                m_Profiles[i].SetDirtyFlag();
            }
        }

        // --- Private Methods ---

        void OnValidate()
        {
            if (m_Profiles.Length > m_maxNumProfiles)
            {
                Array.Resize(ref m_Profiles, m_maxNumProfiles);
            }

            m_NumProfiles = m_Profiles.Length;

            Color c = new Color();

            for (int i = 0; i < m_NumProfiles; i++)
            {
                c.r = Mathf.Clamp(m_Profiles[i].stdDev1.r, 0.05f, 2.0f);
                c.g = Mathf.Clamp(m_Profiles[i].stdDev1.g, 0.05f, 2.0f);
                c.b = Mathf.Clamp(m_Profiles[i].stdDev1.b, 0.05f, 2.0f);
                c.a = 0.0f;

                m_Profiles[i].stdDev1 = c;

                c.r = Mathf.Clamp(m_Profiles[i].stdDev2.r, 0.05f, 2.0f);
                c.g = Mathf.Clamp(m_Profiles[i].stdDev2.g, 0.05f, 2.0f);
                c.b = Mathf.Clamp(m_Profiles[i].stdDev2.b, 0.05f, 2.0f);
                c.a = 0.0f;

                m_Profiles[i].stdDev2 = c;

                m_Profiles[i].lerpWeight = Mathf.Clamp01(m_Profiles[i].lerpWeight);
            }

            m_BilateralScale = Mathf.Clamp01(m_BilateralScale);
        }
    }

    public class SubsurfaceScatteringSettings : Singleton<SubsurfaceScatteringSettings>
    {
        SubsurfaceScatteringParameters settings { get; set; }

        public static SubsurfaceScatteringParameters overrideSettings
        {
            get { return instance.settings; }
            set { instance.settings = value; }
        }
    }

    [CustomEditor(typeof(SubsurfaceScatteringParameters))]
    public class SubsurfaceScatteringParametersEditor : Editor
    {
        private class Styles
        {
            public readonly GUIContent sssCategory          = new GUIContent("Subsurface scattering");
            public readonly GUIContent sssProfileStdDev1    = new GUIContent("SSS profile standard deviation #1", "Determines the shape of the 1st Gaussian filter. Increases the strength and the radius of the blur of the corresponding color channel.");
            public readonly GUIContent sssProfileStdDev2    = new GUIContent("SSS profile standard deviation #2", "Determines the shape of the 2nd Gaussian filter. Increases the strength and the radius of the blur of the corresponding color channel.");
            public readonly GUIContent sssProfileLerpWeight = new GUIContent("SSS profile filter interpolation", "Controls linear interpolation between the two Gaussian filters.");
            public readonly GUIContent sssBilateralScale    = new GUIContent("SSS bilateral filtering scale", "Larger values make the filter more tolerant to depth differences.");
        }

        private static Styles s_Styles;

        private SerializedProperty m_Profiles;
        private SerializedProperty m_BilateralScale;

        // --- Public Methods ---

        private static Styles styles
        {
            get
            {
                if (s_Styles == null)
                {
                    s_Styles = new Styles();
                }
                return s_Styles;
            }
        }

        public override void OnInspectorGUI()
        {
            serializedObject.Update();

            EditorGUI.BeginChangeCheck();
            EditorGUILayout.PropertyField(m_Profiles, true);
            EditorGUILayout.PropertyField(m_BilateralScale, styles.sssBilateralScale);
            if (EditorGUI.EndChangeCheck())
            {
                serializedObject.ApplyModifiedProperties();
                // Serialization ignores setters.
                ((SubsurfaceScatteringParameters)target).SetDirtyFlag();
            }
        }

        // --- Private Methods ---

        void OnEnable()
        {
            m_Profiles       = serializedObject.FindProperty("m_Profiles");
            m_BilateralScale = serializedObject.FindProperty("m_BilateralScale");
        }
    }
}
